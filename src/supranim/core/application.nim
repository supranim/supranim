#
# Supranim is a high-performance web framework for building
# web applications and microservices in Nim
# 
#   (c) 2026 LGPL-v3-or-later License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#
import std/[macros, os, net, tables, strutils, hashes, macrocache, posix]

import pkg/threading/[once, rwlock, channels]

import pkg/kapsis
import pkg/kapsis/interactive/prompts
import pkg/openparser/[json, yaml, toml]

import ../network/webserver
import ./[config, paths, request, response, router]
import pkg/powpow/proto/httpserver
export httpserver.HttpServerOptions

import ../support/uuid

export json, yaml, toml, paths, macros
export registerCallback, unregisterCallback
# Re-export the configuration API (`Configuration` variant, loaders,
# `config()`/`staticConfig()` support). `config` itself is the runtime
# accessor proc below, so the module is exported member-wise.
export Configuration, ConfigurationFormat, ConfigValue, ConfigError,
  ConfigEntry, configFileExtensions, formatForExt,
  parseConfiguration, loadConfigurations, scanConfigDir, stripStatic,
  get, isNil, getStr, getInt, getFloat, getBool,
  putStr, putInt, putFloat, putBool,
  staticConfig, staticConfigFromDir
# NOTE: `threading/channels` is intentionally NOT re-exported here.
# It provides generic `send`/`recv` overloads that would leak into every
# importer and break overload resolution in macro-generated code.
# `Chan`/`ServiceMsg` reach service code via `supranim/core/services`,
# which imports `threading/channels` directly.

type
  JsonString* = string  # an alias for JSON string

  Services* = object
    services: Table[string, pointer]

  # ApplicationUDP* = object
  #   # udpServer*: UdpServer
  #     # A UDP socket for network communication

  ApplicationAssetsHandler* = proc (req: var Request, res: var Response, foundRes: var bool) {.closure.}
  ApplicationThreadCallback* = proc (app: ptr ApplicationObject) {.closure.}

  ServiceMsg* = object
    ## Envelope exchanged between the main application and
    ## channel-based (`ThreadService`) services.
    ## The `Application` owns one `Chan[ServiceMsg]` per service,
    ## created at `start*Service` time and shared with the worker thread.
    ## There is no `close` for `Chan`; workers exit on the `ServiceStopAction`
    ## poison pill sent by the generated `stop*Service` proc.
    id*: int64
    action*: string
    payload*: string

  ApplicationObject = object
    key*: Uuid
      ## The unique application instance key
    port: Port
      ## The port number the application listens on
    address*: string
      ## The address the application binds to
    configs*: OrderedTableRef[string, Configuration]
      ## A table of configuration documents, one per config file
      ## (`.yml`/`.yaml`, `.toml`, `.json`), stored natively.
      ## Top-level `static` blocks are stripped at load time;
      ## read compile-time settings via `staticConfig[T]()` instead.
    applicationPaths* : ApplicationPaths
      ## The application paths object that manages directory paths for the application
    assetsHandler*: ApplicationAssetsHandler
      ## Custom handler for serving static assets. If not defined,
      ## static assets will be served from the `assets/` directory in
      ## the application root. In development this is convenient, but
    server*: WebServer
      ## The web server instance that handles incoming HTTP requests.
      ## This is initialized when the application starts.
    router*: HttpRouterInstance
      ## The HTTP router instance that manages route registration and request handling.
      ## This is initialized during application setup.
    threadChans*: TableRef[string, Chan[ServiceMsg]]
      ## Application-owned channels for `ThreadService` job-threads,
      ## keyed by service name. Created by the generated `start*Service`
      ## proc, looked up by the generated `api` handles and by
      ## `sendServiceMsg` / `recvServiceMsg` below.

  AppConfigDefect* = object of CatchableError

proc info*(str: string, indentSize = 0) =
  echo indent(str, indentSize)

#
# ApplicationObject Instance
#
var
  App*: ptr ApplicationObject
  onceApp = createOnce()

type
  Application* = ptr ApplicationObject
    ## Alias for the application object pointer

proc initApplication* =
  ## Initialize the application and returns the singleton instance
  once(onceApp):
    App = createShared(ApplicationObject)
    App[].applicationPaths = ApplicationPaths()
    App[].threadChans = newTable[string, Chan[ServiceMsg]]()

proc appInstance*: Application =
  ## Returns the singleton application instance
  # TODO rename to `app()`
  initApplication()
  result = App

proc AppInstance*: Application =
  ## Returns the singleton application instance
  initApplication()
  result = App

proc getApplication*: Application =
  ## Returns the singleton application instance
  initApplication()
  result = App

proc app*: Application =
  ## An alias for `getApplication`, returning a singleton app instance
  getApplication()

proc paths*(app: Application): ApplicationPaths =
  ## Returns the application paths
  result = app.applicationPaths

#
# Config API
#
proc config*(app: Application, key: string): ConfigValue =
  ## Runtime configuration lookup. `key` has the shape `file.key.path`;
  ## the value is read from the natively-parsed document and wrapped in
  ## a `ConfigValue` — use `getStr`/`getInt`/`getFloat`/`getBool` on it.
  ## Unknown files and missing keys return a nil node (check with `isNil`).
  let dotIdx = key.find('.')
  if dotIdx <= 0 or dotIdx == key.len - 1:
    return ConfigValue(format: cfgYaml, yamlNode: nil)
  let id = key[0 ..< dotIdx]
  let rest = key[dotIdx + 1 .. ^1]
  if not system.isNil(app.configs) and app.configs.hasKey(id):
    return app.configs[id].get(rest)
  return ConfigValue(format: cfgYaml, yamlNode: nil)

proc loadServerOptions*(app: Application, prefix = "app.server"): HttpServerOptions =
  ## Builds powpow `HttpServerOptions` from `<prefix>.*` runtime config
  ## (`max_body_size`, `read_timeout_ms`, ...). Missing keys keep the
  ## powpow defaults from `defaultHttpServerOptions()`.
  result = defaultHttpServerOptions()
  template opt(key: string, dst: untyped) =
    block:
      let v = app.config(prefix & "." & key)
      if not v.isNil:
        dst = typeof(dst)(v.getInt)
  opt("max_body_size", result.maxBodySize)
  opt("max_stream_body_size", result.maxStreamBodySize)
  opt("max_file_size", result.maxFileSize)
  opt("max_field_size", result.maxFieldSize)
  opt("max_connections", result.maxConnections)
  opt("max_pipeline_depth", result.maxPipelineDepth)
  opt("read_timeout_ms", result.readTimeoutMs)
  opt("ws_idle_timeout_ms", result.wsIdleTimeoutMs)
  opt("timeout_sweep_ms", result.timeoutSweepMs)
  opt("keep_alive_timeout_ms", result.keepAliveMs)

when defined supranimEmbedConfig:
  proc embedConfigs: NimNode {.compileTime.} =
    ## Reads the application's `config/` directory at compile time and
    ## generates code that initializes `App.configs` from the embedded
    ## `.yml`/`.yaml`, `.toml` and `.json` files.
    result = newStmtList()
    add result, quote do:
      App.configs = newOrderedTable[string, Configuration]()
    for entry in scanConfigDir(configPath):
      let
        key = newLit(entry.name)
        ext = newLit(entry.ext)
        content = newLit(readFile(entry.path))
        cfg = newLit(entry.path)
      add result, quote do:
        try:
          App.configs[`key`] = parseConfiguration(`ext`, `content`)
          App.configs[`key`].stripStatic()
        except ConfigError as e:
          displayError(e.msg & "\n" & `cfg`, quitProcess = true)

macro seedEmbeddedEnvSample*(destFile: string): untyped =
  ## Emits a `writeFile` seeding `destFile` with the project's
  ## `.env.sample` baked into the binary at compile time.
  ## Emits nothing when the project has no `.env.sample`, and never
  ## touches an existing file. This is what lets a binary built on
  ## another machine (e.g. a GH Action runner without the project
  ## sources) bootstrap a fresh runtime directory on first `start`.
  result = newStmtList()
  let samplePath = rootPath / ".env.sample"
  if fileExists(samplePath):
    let content = newLit(readFile(samplePath))
    result = quote do:
      if not fileExists(`destFile`):
        writeFile(`destFile`, `content`)

macro seedEmbeddedConfigs*(runtimePath: string): untyped =
  ## Emits one guarded `writeFile` per project config file, seeding
  ## `<runtimePath>/config/<name><ext>` from the contents baked into
  ## the binary at compile time. Existing files are never touched.
  ## Duplicate base names are left for the runtime loader to report,
  ## exactly as it does today.
  result = newStmtList()
  var entries: seq[ConfigEntry] = @[]
  try:
    entries = scanConfigDir(configPath)
  except ConfigError:
    return
  for entry in entries:
    let
      fname = newLit(entry.name & entry.ext)
      content = newLit(readFile(entry.path))
    result.add quote do:
      block:
        let dest = `runtimePath` / "config" / `fname`
        if not fileExists(dest):
          writeFile(dest, `content`)

#
# ApplicationObject API
#
template initHttpRouter* =
  App.key = newUuidV4()
  macro initHttpRouterMacro() =
    result = newStmtList()
    var registerRoutes = newStmtList()
    for k, ctrl in queuedRoutes:
      add registerRoutes, ctrl
    add result, quote do:
      assert App != nil, "Application instance is not initialized"
    add result,
      newProc(
        ident"loadRoutes",
        body = nnkStmtList.newTree(
          nnkPragmaBlock.newTree(
            nnkPragma.newTree(ident"gcsafe"),
            nnkStmtList.newTree(
              newAssignment(
                newDotExpr(ident"App", ident"router"),
                newCall(ident"newHttpRouter")
              ),
              registerRoutes
            )
          )
        ),
      )
    add result, newCall(ident"loadRoutes")
    add result, quote do:
      App.router.errorHandler(Http404, get4xx)
  initHttpRouterMacro()

when defined supraMicroservice:
  # Supranim's microservice architecture
  # builds pluggable modules as Shared Libraries.
  proc loadPluggableModules*(app: ApplicationObject) =
    ## Autoload pluggable modules from dynamic libraries
    displayInfo("Autoload Pluggable Modules")
    for path in walkDirRec(binPath / "modules" / "controller"):
      if path.endsWith(".dylib"):
        var lib: LibHandle = dynlib.loadLib(path)
        if not lib.isNil:
          let callableHandle = cast[PluggableController](lib.symAddr("getTestpage"))
          if not callableHandle.isNil:
            app.modules.controller[hash("getTestpage")] = callableHandle
          else: discard
  
  proc enablePluginManager(app: ApplicationObject) =
    displayInfo("Enable Plugin Manager")
    app.pluginmanager = initPluginManager()
    for path in walkDirRec(binPath / "modules" / "controller"):
      let module: ptr AutoloadPluggableModule =
        app.pluginmanager.autoloadModule(path, rootPath)
      if not module.isNil:
        for route in module[].routes[].routes:
          app.router.registerRoute((route[1], route[2]), route[3], module[].controllers[route[0]])
  
  # proc controllers*(app: ApplicationObject, key: string): PluggableController =
  #   ## Retrieves a Pluggable Controller by `key`. If not found
  #   ## returns `nil`
  #   let key = hash(key)
  #   if likely(app.modules.controller.hasKey(key)):
  #     result = app.modules.controller[key]

  # proc exec*(ctrl: PluggableController, req: ptr Request, res: ptr Response) =
  #   ## Executes a Pluggable Controller
  #   if likely(not ctrl.isNil):
  #     ctrl(req, res)
  #   else:
  #     res[].code = HttpCode(500)

  # proc getModel*(app: ApplicationObject, k: string): PluggableModel =
  #   ## Retrieve a Pluggable Model
  #   let k = hash(k)
  #   if likely(app.modules.model.hasKey(k)):
  #     result = app.modules.model[k]

else:
  #
  # Supranim's monolithic architecture.
  #
  # Bundle Middleware, Controller and Route modules
  # as part of the main application
  #
  proc loadEventListeners*: NimNode {.compileTime.} =
    # walks recursively and auto discover event listeners
    result = newStmtList()
    # add result, newCall(ident"initEventManager")
    for f in walkDirRec(eventsPath / "listeners"):
      if f.endsWith(".nim"):
        if f.splitFile.name[0] notin ['!', '_']:
          add result, nnkImportStmt.newTree(newLit(f))

  proc loadEventQueues*: NimNode {.compileTime.} =
    # walks recursively and auto discover queue jobs
    # available at `src/service/event/queue/*.nim`.
    # nim files prefixed with `!` or `_` will be ignored
    result = newStmtList()
    if dirExists(eventsPath / "queue"):
      for f in walkDirRec(eventsPath / "queue"):
        if f.endsWith(".nim"):
          if f.splitFile.name[0] notin ['!', '_']:
            add result, nnkImportStmt.newTree(newLit(f))
  
  proc loadMiddlewares: NimNode {.compileTime.} =
    # walks recursively and auto discover middleware handles
    # available at /middleware/*.nim.
    result = newStmtList()
    for fMiddleware in walkDirRec(middlewarePath):
      if fMiddleware.endsWith(".nim"):
        let f = fMiddleware.splitFile
        if f.name[0] notin ['!', '_']:
          add result, nnkImportStmt.newTree(newLit(fMiddleware))
          let x = newLit(f.name)

  proc loadControllers: NimNode {.compileTime.} =
    # walks recursively and auto discover controllers
    # available at /controller/*.nim
    # nim files prefixed with `!` will be ignored
    result = newStmtList()
    for fController in walkDirRec(basePath / "controller"):
      if fController.endsWith(".nim"):
        let f = fController.splitFile
        if f.name[0] notin ['!', '_']:
          add result, nnkImportStmt.newTree(newLit(fController))

macro init*(appInstance; skipLocalConfig: static bool = false, initBody: untyped = nil) =
  ## Initializes Supranim application instance. This macro is responsible for
  ## setting up the application, loading configurations, initializing services, and preparing the app to handle incoming requests.
  ## The `initBody` parameter allows injection of custom initialization code during the application setup process.
  result = newStmtList()
  add result, quote do:
    import std/[httpcore, macros, macrocache, options]
    import pkg/supranim/core/[request, response]

    import pkg/kapsis/[framework, runtime, types]
    import pkg/kapsis/interactive/prompts

  add result, newCall(ident"initApplication")
  if not skipLocalConfig:
    # Some Supranim-based apps may want to skip the loading of local configuration files
    # when the structure of the application is different from the default one.
    # In such cases, the `skipLocalConfig` parameter can be set to `true` to
    # skip the loading of local config files.
    when not compileOption("app", "lib"):
      # Application Initialization via Kapsis CLI
      when defined supranimEmbedConfig:
        # config files are embedded into the binary at compile time
        add result, embedConfigs()
      else:
        add result, quote do:
          try:
            App.configs = loadConfigurations(App.applicationPaths.resolve("config"))
          except ConfigError as e:
            displayError(e.msg, quitProcess = true)
  
  if initBody != nil:
    add result, quote do:
      `initBody`

  #
  # Autoload Service Providers
  #
  var serviceProviders = newNimNode(nnkStmtList)
  for path in walkDirRec(servicePath / "provider"):
    let f = path.splitFile
    if f.ext == ".nim" and f.name[0] notin ['_', '!']:
      serviceProviders.add(nnkImportStmt.newTree(newLit(path)))

  when defined supraMicroservice:
    add result, quote do:
      app.router.errorHandler(Http404, DefaultHttpError)
      app.router.errorHandler(Http500, DefaultHttpError)
      app.enablePluginManager()
  else:
    add result, loadEventListeners()
    add result, loadEventQueues()
    add result, loadMiddlewares()
    
    # include `routes.nim` module
    add result, nnkIncludeStmt.newTree(
      newLit(basePath / "routes.nim"))

    add result, loadControllers()

    # inject the base middlewares and route handlers before 
    # adding the service providers, so that they are available to all services.
    add result, quote do:
      initHttpRouter()

    # add the service providers
    add result, serviceProviders

const SafeThreadVarSeq* = CacheSeq"WithThreadCallbackStmt"
  ## A macro cache sequence that stores thread-safe initializations that need to be executed
  ## in the context of the application thread. This is used to ensure that certain operations that require
  ## access to the application instance or its resources are performed in a thread-safe manner.

macro withThreadCallback*(appInstance, callback: untyped) =
  ## Registers a callback to be executed in the context of
  ## the application thread. This is useful for performing thread-safe
  ## operations that require access to the application instance or its resources.
  SafeThreadVarSeq.add(callback)

macro injectSafeThreadCallbacks*() =
  ## Expands the registered thread callbacks into actual procedure calls
  ## that will be executed in the application thread context.
  var stmt = newStmtList()

  # injects supranim threadvar router and error handlers
  # stmt.add quote do:
  #   initRouter()
  #   Router.errorHandler(Http404, get4xx)

  for callback in SafeThreadVarSeq:
    stmt.add(callback)
  
  result = newProc(
    name = ident("startupCallback"),
    pragmas = nnkPragma.newTree(ident"thread"),
    body = nnkPragmaBlock.newTree(
      # marks the procedure as GC-safe to allow it to be called from a GC-safe context
      nnkPragma.newTree(ident"gcsafe"),
      stmt
    )
  )

var appInitialized* = false
  # This flag is used to track whether the application has been initialized via CLI.
  # If the application is not initialized, it will not start
  # the server and will exit instead to prevent unintended execution.

template initStartCommand*(v: Values, createDirs = true) =
  ## Kapsis `init` command handler
  displayInfo("Initializing application...")
  let path = $(v.get("project").getPath)
  if App.applicationPaths.init(path, createDirs):
    # try to initialize the application
    let runtimePath = App.applicationPaths.getInstallationPath()
    displayInfo(span("Runtime path:"), cyanSpan(runtimePath))
    # Seed the runtime `.env` on first run (existing files are never
    # touched), then load it into the process environment. The project's
    # own `.env` wins when the sources are present (local dev); otherwise
    # the `.env.sample` baked into the binary seeds a fresh runtime, so a
    # binary built on another machine (e.g. a GH Action runner) bootstraps
    # without the project sources.
    let runtimeEnv = runtimePath / ".env"
    if not fileExists(runtimeEnv):
      if fileExists(rootPath / ".env"):
        copyFile(rootPath / ".env", runtimeEnv)
      else:
        seedEmbeddedEnvSample(runtimeEnv)
        if not fileExists(runtimeEnv) and fileExists(rootPath / ".env.sample"):
          copyFile(rootPath / ".env.sample", runtimeEnv)
    try:
      loadEnv(runtimePath)
    except SupranimEnvLoader as e:
      displayError(e.msg, quitProcess = true)
    when not defined supranimEmbedConfig:
      # Seed the runtime config directory from the project sources when
      # present (local dev), backfilled from the configs baked into the
      # binary (covers binaries built elsewhere, e.g. a GH Action
      # runner). Existing files are never touched; new defaults (e.g.
      # configs added by recipes after the first run) are backfilled
      # automatically.
      createDir(runtimePath / "config")
      if dirExists(configPath):
        for file in walkFiles(configPath / "*"):
          let f = file.splitFile
          if f.ext.toLowerAscii in configFileExtensions:
            let dest = runtimePath / "config" / f.name & f.ext
            if not fileExists(dest): copyFile(file, dest)
      seedEmbeddedConfigs(runtimePath)
      # `App.init` loaded configs before the installation path was
      # known; refresh from the now-seeded runtime directory so the
      # service providers below see the real configuration.
      try:
        App.configs = loadConfigurations(runtimePath / "config")
      except ConfigError as e:
        displayError(e.msg, quitProcess = true)
    appInitialized = true

template cli*(app: Application, cliCommands) {.dirty.} =
  ## Injects CLI commands into the application using Kapsis command framework
  macro registerCommands(cliCmds) =
    result = newStmtList()
    when not compileOption("app", "lib"):
      # register CLI commands only if the application is not built as a library
      var cliCommandsStmt = nnkStmtList.newTree(
        nnkCall.newTree(
          newIdentNode("initKapsis"),
          nnkStmtList.newTree(
            nnkCall.newTree(newIdentNode("commands"), cliCmds)
          )
        )
      )
      add result, quote do:
        `cliCommandsStmt` # inject the CLI commands into the application
        if not appInitialized: quit() # prevent the application from running if it has not been initialized via CLI
  registerCommands(cliCommands)

template services*(app: Application, servicesStmt) {.inject.} =
  macro preloadServices(node) =
    result = newStmtList()
    add result, nnkImportStmt.newTree(
      nnkInfix.newTree(
        ident"/",
        ident"supranim",
        nnkInfix.newTree(
          ident"/",
          ident"core",
          ident "services"
        )
      )
    )
    var blockStmt = newNimNode(nnkBlockStmt)
    add blockStmt, newEmptyNode()
    add blockStmt, node
    add result, blockStmt
    # add result, newCall(ident"extractThreadServicesBackend")
    # add result, newCall(ident"extractThreadServicesClient")
  preloadServices(servicesStmt)

macro initApp*(args: varargs[untyped]): untyped =
  ## Minimal DSL for the main application file. Wraps the standard
  ## initializer (`App.init`) and forwards each section to the matching
  ## template, so current behavior is unchanged — only the shape changes:
  ##
  ## .. code-block:: nim
  ##   initApp:
  ##     cli do:
  ##       start path(project):
  ##         initStartCommand(v, createDirs = false)
  ##     services do:
  ##       storage.init(App)
  ##     assets "/static": # optional public path, default "/assets"
  ##       assets.embedAssets("assets")
  ##       assets.embedDirectory("storage/icons", "icons")
  ##       assets.preloadBundle("assets")
  ##       assets.preloadBundle("icons")
  ##
  ## Apps that skip the default config loading (like StupidGreen) pass
  ## the flag through and provide the init body as a `config` section:
  ##
  ## .. code-block:: nim
  ##   initApp(skipLocalConfig = true):
  ##     config do:
  ##       App.configs["app"] = parseConfiguration(".toml", "...")
  ##     cli do:
  ##       ...
  ##
  ## `cli do:` / `services do:` sections are forwarded to the `App.cli` /
  ## `App.services` templates. The `assets` section holds the user's own
  ## embed statements, emitted verbatim under `when defined release`
  ## (after an automatic `import pkg/supranim/service/assets`), followed
  ## by the predefined assets handler: embedded bundle, disk `/assets`
  ## fallback, then theme fallback when the app provides
  ## `resolvePublicAsset`. A custom public path remaps embedded lookups
  ## from the bundle namespace (`/<lastPathPart(embedDir)>/...`, taken
  ## from the first `embedAssets`/`embedDirectory` call) onto the URL
  ## prefix. Omit the section for no handler. Anything after this macro
  ## (`App.run`, etc.) stays as is.
  ##
  ## Any other statements (e.g. `startCommand`/`updateCommand` handler
  ## procs, which kapsis resolves by command-name convention and which
  ## need the imports `App.init` injects) are emitted verbatim, in order,
  ## between `App.init()` and the section expansions. Anything after this
  ## macro (`App.run`, etc.) stays as is.
  var
    skipLocalConfig = false
    skipGiven = false
    mainBody: NimNode = nil
  if args.len == 0:
    error("initApp expects a body block")
  for opt in args[0 .. ^2]:
    # `initApp:` alone passes just the body; anything before the final
    # node must be a `skipLocalConfig = <bool>` option.
    if args.len == 1:
      break
    if opt.kind != nnkExprEqExpr or opt[0].kind != nnkIdent or
        opt[0].strVal != "skipLocalConfig":
      error("initApp accepts only a `skipLocalConfig = true|false` option", opt)
    skipGiven = true
    if opt[1].kind in {nnkIdent, nnkSym}:
      skipLocalConfig = opt[1].strVal == "true"
    else:
      skipLocalConfig = repr(opt[1]).strip() == "true"
  mainBody = args[^1]
  if mainBody.kind == nnkDo:
    mainBody = mainBody[^1]
  if mainBody.kind != nnkStmtList:
    error("initApp expects a body block", args)
  result = newStmtList()
  var configBody: NimNode = nil
  for section in mainBody:
    if section.kind in {nnkCommand, nnkCall} and section.len == 2 and
        section[0].kind == nnkIdent and section[0].strVal == "config":
      if configBody != nil:
        error("initApp accepts only one `config do:` section", section)
      let last = section[^1]
      if last.kind == nnkDo:
        configBody = last[^1]
      elif last.kind in {nnkStmtList, nnkStmtListExpr}:
        configBody = last
      else:
        error("initApp: expected `config do:` with a body block", section)
  if configBody == nil and not skipGiven:
    add result, quote do:
      App.init()
  else:
    # NOTE: built manually so the node matches the parser-native shape
    # of `App.init(skipLocalConfig = true) do: ...`
    # (`nnkCall[dotExpr, exprEqExpr?, stmtList?]`).
    var initCall = nnkCall.newTree(
      nnkDotExpr.newTree(ident"App", ident"init"))
    if skipGiven:
      initCall.add nnkExprEqExpr.newTree(
        ident"skipLocalConfig", newLit(skipLocalConfig))
    if configBody != nil:
      initCall.add configBody
    add result, initCall
  var sections = newSeq[NimNode]()
  for s in mainBody:
    if s.kind in {nnkCommand, nnkCall} and s.len == 2 and
        s[0].kind == nnkIdent and s[0].strVal == "config":
      continue
    sections.add(s)
  let resolveSym = ident"resolvePublicAsset"
  for section in sections:
    if section.kind in {nnkCommand, nnkCall} and section.len >= 2:
      var secName = ""
      let head = section[0]
      if head.kind == nnkIdent:
        secName = head.strVal
      elif head.kind == nnkDotExpr and head[^1].kind == nnkIdent:
        secName = head[^1].strVal
      if secName in ["cli", "services"]:
        let last = section[^1]
        var inner: NimNode
        if last.kind == nnkDo:
          inner = last[^1]
        elif last.kind in {nnkStmtList, nnkStmtListExpr}:
          inner = last
        else:
          error("initApp: expected `cli do:` / `services do:` with a body block", section)
        # NOTE: built manually, not via `quote do:`, so the generated
        # `App.cli do:` / `App.services do:` call has exactly the
        # parser-native shape (`nnkCall[dotExpr, stmtList]`).
        add result, newCall(
          nnkDotExpr.newTree(ident"App", ident(secName)),
          inner
        )
        continue
      if secName == "assets":
        # `assets` section: the body holds the user's own embed statements
        # (`assets.embedAssets(...)`, `assets.embedDirectory(...)`,
        # `assets.preloadBundle(...)`), emitted verbatim under
        # `when defined release`, followed by the predefined assets
        # handler. An optional public path (`assets "/static":`) exposes
        # the bundle under a custom URL prefix instead of `/assets`.
        let last = section[^1]
        var assetsBody: NimNode
        if last.kind == nnkDo:
          assetsBody = last[^1]
        elif last.kind in {nnkStmtList, nnkStmtListExpr}:
          assetsBody = last
        else:
          error("initApp: expected `assets:` / `assets \"<path>\":` with a body block", section)
        var pubPath = "/assets"
        if section.len > 2:
          if section.len == 3 and section[1].kind == nnkStrLit:
            pubPath = section[1].strVal
          else:
            error("initApp `assets` accepts one optional public path, e.g. `assets \"/static\":`", section)
        if not pubPath.startsWith("/"):
          pubPath = "/" & pubPath
        while pubPath.len > 1 and pubPath.endsWith("/"):
          pubPath = pubPath[0 .. ^2]
        let guard = if pubPath == "/": "/" else: pubPath & "/"
        # The bundle key namespace follows the embedded directory
        # (`supra bundle.assets` keys files as `/<lastPathPart(dir)>/...`),
        # taken from the first `embedAssets`/`embedDirectory` call.
        var bundlePrefix = "/assets"
        for stmt in assetsBody:
          if stmt.kind in {nnkCommand, nnkCall} and stmt.len >= 2:
            let h = stmt[0]
            if h.kind == nnkDotExpr and h[0].kind == nnkIdent and
                h[0].strVal == "assets" and h[1].kind == nnkIdent and
                h[1].strVal in ["embedAssets", "embedDirectory"] and
                stmt[1].kind == nnkStrLit and stmt[1].strVal.len > 0:
              bundlePrefix = "/" & lastPathPart(stmt[1].strVal)
              break
        # A lone `assets: true` means "default handler, bundling done
        # elsewhere": no user statements to emit.
        var userStmts = assetsBody
        if assetsBody.kind == nnkStmtList and assetsBody.len == 1:
          let only = assetsBody[0]
          let isTrue =
            (only.kind in {nnkIdent, nnkSym} and only.strVal == "true") or
            (only.kind notin {nnkIdent, nnkSym} and repr(only).strip() == "true")
          if isTrue:
            userStmts = newStmtList()
        let
          guardLit = newLit(guard)
          bundleLit = newLit(bundlePrefix)
          plenLit = newLit(pubPath.len)
        # When the public path equals the bundle namespace (the default
        # `/assets` case), keep Sunday's exact shape: the embedded bundle
        # is probed with the raw path for every request. Otherwise the
        # embedded probe is scoped inside the public-path guard so the
        # bundle namespace does not leak onto other URLs.
        if pubPath == bundlePrefix:
          add result, quote do:
            when defined release:
              import pkg/supranim/service/assets
              `userStmts`
              App.withAssetsHandler:
                proc (req: var Request, res: var Response, foundRes: var bool) =
                  let assetKey =
                    if req.path.startsWith(`guardLit`):
                      `bundleLit` & req.path[`plenLit` .. ^1]
                    else:
                      req.path
                  when defined release:
                    req.sendEmbeddedAsset(assetKey, res.getHeaders(), foundRes)
                  if not foundRes and req.path.startsWith(`guardLit`):
                    req.sendAssets(req.path, res.getHeaders(), foundRes)
                    if not foundRes:
                      when compiles(`resolveSym`(req.path)):
                        let themeAsset = `resolveSym`(req.path)
                        if themeAsset.len > 0:
                          req.sendAssetFile(themeAsset, res.getHeaders())
                          foundRes = true
        else:
          add result, quote do:
            when defined release:
              import pkg/supranim/service/assets
              `userStmts`
              App.withAssetsHandler:
                proc (req: var Request, res: var Response, foundRes: var bool) =
                  if req.path.startsWith(`guardLit`):
                    when defined release:
                      req.sendEmbeddedAsset(
                        `bundleLit` & req.path[`plenLit` .. ^1],
                        res.getHeaders(), foundRes)
                    if not foundRes:
                      req.sendAssets(req.path, res.getHeaders(), foundRes)
                      if not foundRes:
                        when compiles(`resolveSym`(req.path)):
                          let themeAsset = `resolveSym`(req.path)
                          if themeAsset.len > 0:
                            req.sendAssetFile(themeAsset, res.getHeaders())
                            foundRes = true
        continue
    # Anything else (command handler procs, comments, pragmas) passes
    # through verbatim in order: after `App.init()`'s imports, before the
    # `App.cli` registration below when placed before the `cli` section.
    add result, section

template withAssetsHandler*(app: Application, handler: ApplicationAssetsHandler) =
  ## Inject a custom assets handler into the application. This allows you to define
  ## custom logic for serving static assets (CSS, JS, images, etc.) instead of using the
  ## default static file serving from the `assets/` directory
  app[].assetsHandler = handler

proc getPort*(app: Application): lent Port =
  ## Get port number
  result = app.port

proc getUuid*(app: Application): lent Uuid =
  ## Get ApplicationObject UUID
  result = app.key

proc getAddress*(app: Application): lent string =
  result = app.address

const ServiceStopAction* = "__stop__"
  ## Poison-pill `action` telling a `ThreadService` worker to exit its
  ## message loop. Sent by the generated `stop*Service` proc
  ## (`Chan` has no `close`).

proc registerServiceChan*(app: Application, name: string, ch: Chan[ServiceMsg]) =
  ## Store the application-owned channel for the `ThreadService` called `name`.
  ## Called by the generated `start*Service` proc.
  app.threadChans[name] = ch

proc hasServiceChan*(app: Application, name: string): bool =
  ## Whether a channel is registered for the `ThreadService` called `name`.
  result = app.threadChans.hasKey(name)

proc getServiceChan*(app: Application, name: string): Chan[ServiceMsg] =
  ## Return the application-owned channel for the `ThreadService` called `name`.
  ## Raises `KeyError` when the service was not started.
  result = app.threadChans[name]

proc sendServiceMsg*(app: Application, name, action: string,
    payload: string = "", id: int64 = 0): bool {.discardable.} =
  ## Non-blocking send of a `ServiceMsg` to the `ThreadService` called `name`.
  ## Returns `false` when no channel is registered or the queue is full.
  if likely(app.threadChans.hasKey(name)):
    return app.threadChans[name].trySend(ServiceMsg(id: id, action: action, payload: payload))
  false

proc recvServiceMsg*(app: Application, name: string): ServiceMsg =
  ## Blocking receive of a `ServiceMsg` from the `ThreadService` called `name`.
  ## Used for worker replies sent back on the shared channel.
  result = app.threadChans[name].recv()

proc tryRecvServiceMsg*(app: Application, name: string, dst: var ServiceMsg): bool =
  ## Non-blocking receive of a `ServiceMsg` from the `ThreadService` called `name`.
  if likely(app.threadChans.hasKey(name)):
    return app.threadChans[name].tryRecv(dst)
  false

template isServiceStop*(msg: ServiceMsg): bool =
  ## Whether `msg` is the worker shutdown poison pill.
  msg.action == ServiceStopAction

