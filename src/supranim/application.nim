#
# Supranim is a full-featured web framework for building
# web apps & microservices in Nim.
# 
#   (c) 2025 MIT License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#

import std/[macros, os, tables, strutils, cpuinfo,
    json, jsonutils, hashes, dynlib, envvars, typeinfo,
    macrocache, cmdline, parseopt]

import pkg/threading/[once, channels]
import pkg/[nyml, kapsis]

import pkg/enimsql/model

import ./core/[config, paths, plugins]
import ./http/[request, response, router]

import ./support/uuid
import ./service/events

from std/net import `$`, Port

export json, nyml, paths
export supranimServer

type
  PluggableController* = proc(req: ptr Request, res: ptr Response) {.nimcall, gcsafe.}
  PluggableModules* = object
    controller: Table[Hash, PluggableController]
  
  JsonString* = string  # an alias for JSON string

  ApplicationObject = object
    key*: Uuid
    port: Port
    address: string = "127.0.0.1"
    domain, name: string
    applicationPaths*: ApplicationPaths
      ## A singleton of `ApplicationPaths`
    when defined webapp:
      assets: tuple[source, public: string]
    basepath: string
    configs*: OrderedTableRef[string, nyml.Document]
    router*: type(router.Router)
    when defined supraMicroservice:
      modules: PluggableModules
        # A table of pluggable modules
    pluginManager: PluginManager
      # An instance of the PluginManager
    runtime*: Table[string, string]

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
  App: ptr ApplicationObject
  onceApp = createOnce()

type
  Application* = ptr ApplicationObject

proc initApplication*: Application =
  ## Returns the singleton instance of the application
  once(onceApp):
    App = createSharedU(ApplicationObject)
  result = App

proc appInstance*(): ptr ApplicationObject =
  result = initApplication()

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
  app.key = uuid4()
  macro initHttpRouter() =
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
              newAssignment(
                newDotExpr(ident"app", ident"router"),
                newCall(ident"newHttpRouter")
              ),
              registerRoutes
            )
          )
        ),
        pragmas = nnkPragma.newTree(
          ident "thread"
        )
      )
    add result, newCall(ident"initRouter")
  initHttpRouter()

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
  # Supranim's monolithic architecture.
  # Bundle Middleware, Controller and Route modules
  # as part of the main application
  proc loadEventListeners*: NimNode {.compileTime.} =
    # walks recursively and auto discover event listeners
    result = newStmtList()
    # add result, newCall(ident"initEventManager")
    for f in walkDirRec(eventsPath / "listener"):
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
    
    # include `routes.nim` module
    add result, nnkIncludeStmt.newTree(newLit(basePath / "routes.nim"))

  proc loadControllers: NimNode {.compileTime.} =
    # walks recursively and auto discover controllers
    # available at /controller/*.nim
    # nim files prefixed with `!` will be ignored
    result = newStmtList()
    for fController in walkDirRec(basePath / "controller"):
      if fController.endsWith(".nim"):
        if not fController.splitFile.name.startsWith("!"):
          add result, nnkImportStmt.newTree(newLit(fController))

macro init*(x: untyped) =
  ## Initializes Supranim application
  expectKind(x, nnkLetSection)
  # expectKind(x[0][2], nnkEmpty)
  var commandLineCommands = newEmptyNode()
  if x[0][2].kind == nnkCall:
    commandLineCommands = x[0][2][1] # get the commands block
    x[0][2] = newEmptyNode() # remove commands from init
  
  x[0][2] = newCall(
    newDotExpr(
      ident"supranim",
      ident"initApplication"
    )
  )
  result = newStmtList()
  add result, x
  when not compileOption("app", "lib"):
    # Application Initialization via Kapsis CLI
    loadEnvStatic() # read `.env.yml` config file
    
    var cliCommandsStmt = newStmtList()
    cliCommandsStmt.add(
      newCall(
        ident"commands",
        commandLineCommands
      )
    )
    add result, quote do:
      import pkg/kapsis
      import pkg/kapsis/[cli, runtime]

      var appInitialized = false
      proc startCommand(v: Values) =
        ## Kapsis `init` command handler
        displayInfo("Initialize Application via CLI")
        let path = $(v.get("directory").getPath)
        if app.applicationPaths.init(path):
          # try to initialize the application
          display(span("⚡️ Start Supranim application"))
          display(span"📂 Installation path:", span(app.applicationPaths.getInstallationPath))
          appInitialized = true
          
      kapsis.settings(
        # tell kapsis to not exit after running the callback
        # as we want to continue with the application initialization.
        #
        # if we need to prevent application from running after
        # the callback, will quit the process inside the callback
        exitAfterCallback = false,
      )

      `cliCommandsStmt`
      
      # exit if not initialized
      if not appInitialized: quit()

      block:
        app.configs = newOrderedTable[string, Document]()
        for yamlFilePath in walkPattern(configPath / "*.yml"):
          let configFile = yamlFilePath.splitFile
          try:
            app.configs[configFile.name] = yaml(yamlFilePath.readFile).toJson
          except YAMLException:
            displayError("Invalid YAML configuration: " & yamlFilePath)
    

  #
  # Autoload Singleton modules
  # for first time initialization
  #
  var y = newStmtList()
  var singletonBlockStmt = newNimNode(nnkStmtList)
  for path in walkDirRec(servicePath / "provider"):
    let f = path.splitFile
    if f.ext == ".nim" and f.name.startsWith("!") == false:
      singletonBlockStmt.add(nnkImportStmt.newTree(newLit(path)))
  add y, singletonBlockStmt
  add result, singletonBlockStmt

  add result, quote do:
    import std/[httpcore, macros, macrocache, options]
    import supranim/http/[request, response]

  when defined supraMicroservice:
    add result, quote do:
      app.router.errorHandler(Http404, DefaultHttpError)
      app.router.errorHandler(Http500, DefaultHttpError)
      app.enablePluginManager()
  else:
    add result, loadEventListeners()
    add result, loadMiddlewares()
    add result, loadControllers()
    add result, quote do:
      proc startupCallback() {.gcsafe.} =
        # Initialize the HTTP Router
        {.gcsafe.}:
          initHttpRouter()
          app.router.errorHandler(Http404, errors.get4xx)

type
  AppConfig* = object
    release_unused_memory*: bool = false
      ## Release unused memory on each request/response cycle.
      ## This is useful for long-running applications
      ## that handle a lot of requests and want to
      ## keep memory usage low.

macro appConfig*(releaseUnusedMemory: static bool = false) =
  ## Macro to define compile-time configuration settings
  discard

template services*(app: Application, servicesStmt) {.inject.} =
  macro preloadServices(node) =
    result = newStmtList()
    add result,
      nnkImportStmt.newTree(
        nnkInfix.newTree(
          ident"/",        
          ident"supranim",
          nnkInfix.newTree(
            ident"/",
            ident"core",
            ident "servicemanager"
          )
        )
      )
    var blockStmt = newNimNode(nnkBlockStmt)
    add blockStmt, newEmptyNode()
    add blockStmt, node
    add result, blockStmt
    # add result, newCall(ident"extractThreadServicesBackend")
    add result, newCall(ident"extractThreadServicesClient")
  preloadServices(servicesStmt)

proc getPort*(app: Application): Port =
  ## Get port number
  result = app.port

proc getUuid*(app: Application): Uuid =
  ## Get ApplicationObject UUID
  result = app.key

proc getAddress*(app: Application): string =
  result = app.address
