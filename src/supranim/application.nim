# Supranim is a simple MVC web framework
# for building web apps & microservices in Nim.
#
# (c) 2024 MIT License | Made by Humans from OpenPeeps
# https://supranim.com | https://github.com/supranim


import std/[macros, os, tables, strutils,
    cpuinfo, json, jsonutils, hashes,
    dynlib, envvars, typeinfo, macrocache]

import pkg/[nyml, kapsis]
import pkg/enimsql/model

import ./support/[uuid]
import ./core/[config, paths, pluginmanager]
import ./core/http/router

from std/net import `$`, Port

export json, nyml, paths
export supranimServer

type
  PluggableController* = proc(req: ptr Request, res: ptr Response) {.nimcall, gcsafe.}
  PluggableModules* = object
    controller: Table[Hash, PluggableController]
  
  Application* = ref object
    key*: Uuid
    port: Port
    address: string = "127.0.0.1"
    domain, name: string
    when defined webapp:
      assets: tuple[source, public: string]
    basepath: string
    configs*: OrderedTableRef[string, nyml.Document]
    router*: type(router.Router)
    modules: PluggableModules
    pluginManager: PluginManager

  AppConfigDefect* = object of CatchableError

#
# Application Crypto
#
import pkg/libsodium/[sodium, sodium_sizes]
export bin2hex, hex2bin

proc info*(str: string, indentSize = 0) =
  echo indent(str, indentSize)

#
# Config API
#
proc loadConfig*(app: Application) =
  for ypath in walkPattern(configPath / "*.yml"):
    app.configs[ypath.splitFile.name] = yaml(ypath.readFile).toJson

proc config*(app: Application, key: string): JsonNode =
  let x = key.split(".")
  let id = x[0]
  let keys = x[1..^1]
  if likely(app.configs.hasKey(id)):
    return app.configs[id].get(keys.join("."))

#
# Application API
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
                newCall(ident "newHttpRouter")
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
  proc loadPluggableModules*(app: Application) =
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
  
  proc enablePluginManager(app: Application) =
    displayInfo("Enable Plugin Manager")
    app.pluginmanager = initPluginManager()
    for path in walkDirRec(binPath / "modules" / "controller"):
      let module: ptr AutoloadPluggableModule =
        app.pluginmanager.autoloadModule(path, rootPath)
      if not module.isNil:
        for route in module[].routes[].routes:
          app.router.registerRoute((route[1], route[2]), route[3], module[].controllers[route[0]])
  
  # proc controllers*(app: Application, key: string): PluggableController =
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

  # proc getModel*(app: Application, k: string): PluggableModel =
  #   ## Retrieve a Pluggable Model
  #   let k = hash(k)
  #   if likely(app.modules.model.hasKey(k)):
  #     result = app.modules.model[k]

else:
  # Supranim's monolithic architecture.
  # Bundle Middleware, Controller and Route modules
  # as part of the main application
  proc loadMiddlewares: NimNode {.compileTime.} =
    # walks recursively and auto discover middleware handles
    # available at /middleware/*.nim.
    result = newStmtList()
    for fMiddleware in walkDirRec(basePath / "middleware"):
      if fMiddleware.endsWith(".nim"):
        if not fMiddleware.splitFile.name.startsWith("!"):
          add result, nnkImportStmt.newTree(newLit(fMiddleware))
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

macro init*(x) =
  ## Initializes Supranim application
  expectKind(x, nnkLetSection)
  expectKind(x[0][2], nnkEmpty)
  result = newStmtList()
  x[0][2] = newCall(
    newDotExpr(
      ident"supranim",
      ident"Application"
    )
  )
  add result, x
  when not compileOption("app", "lib"):
    # read `.env.yml` config file
    loadEnvStatic()
    add result, quote do:
      block:
        app.configs = newOrderedTable[string, Document]()
        app.loadConfig()

  if not dirExists(cachePath):
    # creates `.cache` directory inside working project path.
    # here we'll store generated nim files that can be
    # called via `supranim/runtime`
    createDir(cachePath)

  if not dirExists(pluginsPath):
    # Creates `/storage/plugins` directory for storing
    # dynamic libraries aka plugins
    createDir(pluginsPath)

  # autoload /{project}./cache/runtime.nim
  var y = newStmtList()
  var exports = newNimNode(nnkExportStmt)
  for ipcfile in walkDirRec(servicePath / "ipc"):
    let ipcfname = ipcfile.splitFile.name
    if ipcfname.startsWith("!") == false and ipcfile.endsWith(".nim"):
      add y, nnkImportStmt.newTree(
        nnkInfix.newTree(
          ident"as",
          newLit ipcfile,
          ident ipcfname
        )
      )
      add exports, ident ipcfname
  if exports.len > 0:
    add y, exports
    writeFile(cachePath / "runtime.nim", y.repr)
  add result,
    nnkImportStmt.newTree(
      nnkInfix.newTree(
        ident"/",
        ident"supranim",
        nnkBracket.newTree(
          ident"runtime",
        )
      ),
    )
  add result,
    nnkExportStmt.newTree(ident"runtime")

  add result, quote do:
    import supranim/core/[request, response]
    import std/[httpcore, macros, macrocache]
  when defined supraMicroservice:
    add result, quote do:
      app.router.errorHandler(Http404, DefaultHttpError)
      app.router.errorHandler(Http500, DefaultHttpError)
      app.enablePluginManager()
  else:
    add result, loadMiddlewares()
    add result, loadControllers()
    add result, quote do:
      proc startupCallback() {.gcsafe.} =
        {.gcsafe.}:
          initHttpRouter()
          app.router.errorHandler(Http404, errors.get4xx)

template services*(s) {.inject.} =
  macro initServices(x) =
    result = newStmtList()
    var blockStmt = newNimNode(nnkBlockStmt)
    add blockStmt, newEmptyNode()
    add blockStmt, x
    add result, blockStmt
  initServices(s)


#
# Runtime API
#
proc getPort*(app: Application): Port =
  ## Get port number
  result = app.port

proc getUuid*(app: Application): Uuid =
  ## Get Application UUID
  result = app.key

proc getAddress*(app: Application): string =
  result = app.address
