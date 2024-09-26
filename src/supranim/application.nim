# Supranim is a simple MVC web framework
# for building web apps & microservices in Nim.
#
# (c) 2024 MIT License | Made by Humans from OpenPeeps
# https://supranim.com | https://github.com/supranim


import std/[macros, os, tables, strutils, cpuinfo,
          json, jsonutils, envvars, typeinfo, macrocache]

# when compileOption("app", "lib"):
#   static:
#     error("This import is restricted for dynamic libraries")

import pkg/[nyml, zmq]
import pkg/enimsql/model
import ./support/[uuid]

import ./core/[config, paths]
import ./core/http/router

from std/net import `$`, Port

export json, nyml, paths
export supranimServer

type
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

  AppConfigDefect* = object of CatchableError

#
# Application Universal API
#
# var uapi: Thread[void]
# proc runUniversalApi {.thread.} =
#   var router = listen("tcp://127.0.0.1:55000", mode=ROUTER)
#   while true:
#     let sockid = router.receive()
#     if len(sockid) > 0:
#       let recv = router.receiveAll()
#       let commandName = recv[0]
#       router.send(sockid, SNDMORE)
#       echo commandName
#     sleep(100)

# createThread(uapi, runUniversalApi)

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
template initSystemServices*() =
  macro initSystem() =
    result = newStmtList()
    var registerRoutes = newStmtList()
    for k, ctrl in queuedRoutes:
      add registerRoutes, ctrl
    add result,
      newProc(
        nnkPostfix.newTree(
          ident("*"),
          ident("initRouter")
        ),
        body = nnkStmtList.newTree(
          nnkPragmaBlock.newTree(
            nnkPragma.newTree(
              newIdentNode("gcsafe")
            ),
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
    add result,
      newCall(ident"initRouter")
  app.key = uuid4()
  initSystem()

proc loadMiddlewares: NimNode {.compileTime.} =
  # auto discover /middleware/*.nim
  # nim files prefixed with `!` will be ignored
  result = newStmtList()
  for fMiddleware in walkDirRec(basePath / "middleware"):
    if fMiddleware.endsWith(".nim"):
      if not fMiddleware.splitFile.name.startsWith("!"):
        add result, nnkImportStmt.newTree(newLit(fMiddleware))
  add result, nnkIncludeStmt.newTree(
    newLit(basePath / "routes.nim")
  )

proc loadControllers: NimNode {.compileTime.} =
  # walks recursively and auto discover nim modules
  # found in /controller/*.nim
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
  x[0][2] = newCall(ident "Application")
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

  # auto include `routes.nim` file
  add result, quote do:
    import supranim/core/[request, response]
    import std/[httpcore, macros, macrocache]

  add result, loadMiddlewares()
  add result, loadControllers()

  # auto discover /database/models/*.nim
  # nim files prefixed with `!` will be ignored
  # for fModel in walkDirRec(basePath / "database" / "models"):
  #   let f = fModel.splitFile
  #   if f.ext == ".nim":
  #     if not f.name.startsWith("!"):
  #       add result, nnkImportStmt.newTree(newLit(fModel))

  add result, quote do:
    initSystemServices()
    app.router.errorHandler(Http404, errors.get4xx)

template services*(s) {.inject.} =
  macro initServices(x) =
    result = newStmtList()
    var blockStmt = newNimNode(nnkBlockStmt)
    add blockStmt, newEmptyNode()
    add blockStmt, x
    add result, blockStmt
  initServices(s)

proc initDeveloperTools*() =
  discard

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
