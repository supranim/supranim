#
# Supranim is a full-featured web framework for building
# web apps & microservices in Nim.
# 
#   (c) 2026 LGPL-v3-or-later License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#
import std/[macros, os, net, tables, strutils,
          json, hashes, macrocache, posix]

import pkg/[nyml, kapsis, #[cbor_serialization]#]
import pkg/threading/[once, rwlock]
import pkg/libevent/bindings/[http, buffer, event]
import pkg/kapsis/interactive/prompts

import ./[config, paths, request, response, router]

# import ../network/udpserver
import ../support/uuid

export json, nyml, paths, macros
export supranimServer

type
  JsonString* = string  # an alias for JSON string

  Services* = object
    services: Table[string, pointer]

  # ApplicationUDP* = object
  #   # udpServer*: UdpServer
  #     # A UDP socket for network communication

  ApplicationAssetsHandler* = proc (req: var Request, res: var Response, hasFoundResource: var bool) {.closure.}

  ApplicationObject = object
    key*: Uuid
      ## The unique application instance key
    port: Port
      ## The port number the application listens on
    address*: string
      ## The address the application binds to
    configs*: OrderedTableRef[string, nyml.Document]
      ## A table of configuration documents
    # services*: ApplicationServices
      # A table of service providers
    router*: HttpRouterInstance
      ## The main HTTP router instance
    # udp*: ApplicationUDP
    applicationPaths* : ApplicationPaths
      ## The application paths 
    assetsHandler*: ApplicationAssetsHandler
      ## Custom handler for serving static assets. If not defined,
      ## static assets will be served from the `assets/` directory in
      ## the application root. In development this is convenient, but

  AppConfigDefect* = object of CatchableError
  
#
# ApplicationObject Crypto
#
import pkg/libsodium/[sodium, sodium_sizes]
export bin2hex, hex2bin

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

proc appInstance*: Application =
  ## Returns the singleton application instance
  # TODO rename to `app()`
  initApplication()
  result = App

proc paths*(app: Application): ApplicationPaths =
  ## Returns the application paths
  result = app.applicationPaths

#
# Config API
#
proc config*(app: Application, key: string): JsonNode =
  let x = key.split(".")
  let id = x[0]
  let keys = x[1..^1]
  if likely(app.configs.hasKey(id)):
    return app.configs[id].get(keys.join("."))

#
# ApplicationObject API
#
template initHttpRouter* =
  App.key = uuid4()
  macro initHttpRouterMacro() =
    result = newStmtList()
    var registerRoutes = newStmtList()
    for k, ctrl in queuedRoutes:
      add registerRoutes, ctrl

    add result,
      newProc(
        ident"initRouter",
        body = nnkStmtList.newTree(
          nnkPragmaBlock.newTree(
            nnkPragma.newTree(ident"gcsafe"),
            nnkStmtList.newTree(
              # newAssignment(
              #   newDotExpr(ident"App", ident"router"),
              #   newCall(ident"newHttpRouter")
              # ),
              newAssignment(
                ident"Router",
                newCall(ident"newHttpRouter")
              ),
              registerRoutes
            )
          )
        ),
        # pragmas = nnkPragma.newTree(
        #   ident "thread"
        # )
      )
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
          Router.registerRoute((route[1], route[2]), route[3], module[].controllers[route[0]])
  
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
        if not f.splitFile.name.startsWith("!"):
          add result, nnkImportStmt.newTree(newLit(f))
  
  proc loadMiddlewares: NimNode {.compileTime.} =
    # walks recursively and auto discover middleware handles
    # available at /middleware/*.nim.
    result = newStmtList()
    for fMiddleware in walkDirRec(middlewarePath):
      if fMiddleware.endsWith(".nim"):
        let f = fMiddleware.splitFile
        if not f.name.startsWith("!"):
          add result, nnkImportStmt.newTree(newLit(fMiddleware))
          let x = newLit(f.name)

  proc loadControllers: NimNode {.compileTime.} =
    # walks recursively and auto discover controllers
    # available at /controller/*.nim
    # nim files prefixed with `!` will be ignored
    result = newStmtList()
    for fController in walkDirRec(basePath / "controller"):
      if fController.endsWith(".nim"):
        if not fController.splitFile.name.startsWith("!"):
          add result, nnkImportStmt.newTree(newLit(fController))

  proc loadConsole: NimNode {.compileTime.} =
    # walks recursively and auto discover console commands
    # available at /console/*.nim
    result = newStmtList()
    for fConsole in walkDirRec(basePath / "console"):
      if fConsole.endsWith(".nim"):
        if not fConsole.splitFile.name.startsWith("!"):
          add result, nnkImportStmt.newTree(newLit(fConsole))

macro init*(appInstance; skipLocalConfig: static bool = false, initBody: untyped = nil) =
  ## Initializes Supranim application
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
      loadEnvStatic() # read `.env.yml` config file
      add result, quote do:
        App.configs = newOrderedTable[string, Document]()
        for path in walkFiles(App.applicationPaths.resolve("config", "*")):
          let p = path.splitFile
          if p.ext in [".yml", ".yaml"]:
            let configFile = path.splitFile
            try:
              App.configs[p.name] = yaml(readFile(path)).toJson
            except YAMLException:
              displayError("Invalid YAML configuration: " & path, quitProcess = true)
  if initBody != nil:
    add result, quote do:
      `initBody`

  #
  # Autoload Service Providers
  #
  var serviceProviders = newNimNode(nnkStmtList)
  for path in walkDirRec(servicePath / "provider"):
    let f = path.splitFile
    if f.ext == ".nim" and f.name.startsWith("!") == false:
      serviceProviders.add(nnkImportStmt.newTree(newLit(path)))

  when defined supraMicroservice:
    add result, quote do:
      Router.errorHandler(Http404, DefaultHttpError)
      Router.errorHandler(Http500, DefaultHttpError)
      app.enablePluginManager()
  else:
    add result, loadEventListeners()
    add result, loadMiddlewares()
    
    # include `routes.nim` module
    add result, nnkIncludeStmt.newTree(
      newLit(basePath / "routes.nim"))

    add result, loadControllers()

    # when found, will load console commands
    add result, loadConsole()

    # initialize the HTTP Router
    add result, quote do:
      initHttpRouter()
      proc startupCallback() {.gcsafe.} =
        {.gcsafe.}:
          initRouter()
          Router.errorHandler(Http404, get4xx)
    
    # add the service providers
    add result, serviceProviders

# type
#   AppConfig* = object
#     release_unused_memory*: bool = false
#       ## Release unused memory on each request/response cycle.
#       ## This is useful for long-running applications
#       ## that handle a lot of requests and want to
#       ## keep memory usage low.

# macro appConfig*(releaseUnusedMemory: static bool = false) =
#   ## Macro to define compile-time configuration settings
#   discard

var AppCommands = CacheTable"AppCommands"
var appInitialized* = false

template initStartCommand*(v: Values, createDirs = true) =
  ## Kapsis `init` command handler
  displayInfo("Initialize Application via CLI")
  let path = $(v.get("directory").getPath)
  if App.applicationPaths.init(path, createDirs):
    # try to initialize the application
    let runtimePath = App.applicationPaths.getInstallationPath()
    display(span("⚡️ Start Supranim application"))
    display(span"📂 Installation path:", span(runtimePath))
    if not dirExists(runtimePath / "config"):
      # create runtime config directory and copy default config files.
      createDir(runtimePath / "config")
      for file in walkFiles(paths.configPath / "*"):
        let f = file.splitFile
        if f.ext in [".yml", ".yaml"]:
          let dest = runtimePath / "config" / f.name & f.ext
          if not fileExists(dest): copyFile(file, dest)
    appInitialized = true

template cli*(app: Application, cliCommands) {.dirty.} =
  ## Injects CLI commands into the application
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
    add result, newCall(ident"extractThreadServicesBackend")
    # add result, newCall(ident"extractThreadServicesClient")
  preloadServices(servicesStmt)

template withAssetsHandler*(app: Application, handler: ApplicationAssetsHandler) =
  ## Define a custom handler for serving static assets
  app[].assetsHandler = handler

proc getPort*(app: Application): Port =
  ## Get port number
  result = app.port

proc getUuid*(app: Application): Uuid =
  ## Get ApplicationObject UUID
  result = app.key

proc getAddress*(app: Application): string =
  result = app.address

