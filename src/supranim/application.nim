# Supranim is a simple MVC web framework
# for building web apps & microservices in Nim.
#
# (c) 2024 MIT License | Made by Humans from OpenPeeps
# https://supranim.com | https://github.com/supranim

import std/[macros, os, tables, strutils, cpuinfo,
          json, jsonutils, envvars, typeinfo, macrocache]

import pkg/nyml
import pkg/enimsql/model
import support/[uuid]

from std/net import `$`, Port

export json, nyml

type
  Application* = ref object
    key: Uuid
    port: Port
    address: string = "127.0.0.1"
    domain, name: string
    when defined webapp:
      assets: tuple[source, public: string]
    basepath: string
    configs*: OrderedTableRef[string, nyml.Document]

  AppConfigDefect* = object of CatchableError

const
  supranimBasePath {.strdefine.} = getProjectPath()
  basePath* = supranimBasePath
  rootPath* = normalizedPath(basepath.parentDir)
  binPath* = normalizedPath(rootPath / "bin")
  cachePath* = normalizedPath(rootPath / ".cache")
  runtimeConfigPath* = cachePath / "runtime" / "config"
  configPath* = basepath / "config"
  controllerPath* = basepath / "controller"
  middlewarePath* = basepath / "middleware"
  databasePath* = basepath / "database"
  servicePath* = basepath / "service"
  modelPath* = databasePath / "models"
  migrationPath* = databasePath / "migrations"
  storagePath* = basepath / "storage"
  logsPath* = storagePath / "logs"

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
          newAssignment(
            ident "Router",
            newCall(ident "newRouter")
          ),
          registerRoutes
        ),
        pragmas = nnkPragma.newTree(
          ident "thread"
        )
      )
  initSystem()

macro loadEnvStatic* =
  let
    envContents = staticRead(rootPath / ".env.yml")
    ymlEnv = yaml(envContents).toJson
  when not defined release:
    let
      dbUser = ymlEnv.get("database.local.user").getStr
      dbName = ymlEnv.get("database.local.name").getStr
      dbPassword = ymlEnv.get("database.local.password").getStr
      dbPort = ymlEnv.get("database.local.port").getStr
  else:
    let
      dbUser = ymlEnv.get("database.prod.user").getStr
      dbName = ymlEnv.get("database.prod.name").getStr
      dbPassword = ymlEnv.get("database.prod.password").getStr
      dbPort = ymlEnv.get("database.prod.port").getStr
  result = newStmtList()
  add result, quote do:
    putEnv("database.user", `dbUser`)
    putEnv("database.name", `dbName`)
    putEnv("database.password", `dbPassword`)
    putEnv("database.port", `dbPort`)

macro init*(x) =
  ## Initializes the Application
  expectKind(x, nnkLetSection)
  expectKind(x[0][2], nnkEmpty)
  result = newStmtList()
  x[0][2] = newCall(ident "Application")
  add result, x
  echo dirExists(cachePath)
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

  add result,
    nnkImportStmt.newTree(
      nnkInfix.newTree(
        ident"/",
        ident"std",
        nnkBracket.newTree(
          ident"tables",
          ident"envvars",
          ident"typeinfo"
        )
      )
    )

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
    import ./core/[request, response]
    import std/[httpcore, macros, macrocache]

  # auto discover /middleware/*.nim
  # nim files prefixed with `!` will be ignored
  for fMiddleware in walkDirRec(basePath / "middleware"):
    if fMiddleware.endsWith(".nim"):
      if not fMiddleware.splitFile.name.startsWith("!"):
        add result, nnkImportStmt.newTree(newLit(fMiddleware))

  add result, nnkIncludeStmt.newTree(newLit(basePath / "routes.nim"))

  # auto discover /controller/*.nim
  # nim files prefixed with `!` will be ignored
  for fController in walkDirRec(basePath / "controller"):
    if fController.endsWith(".nim"):
      if not fController.splitFile.name.startsWith("!"):
        add result, nnkImportStmt.newTree(newLit(fController))

  # auto discover /database/models/*.nim
  # nim files prefixed with `!` will be ignored
  for fModel in walkDirRec(basePath / "database" / "models"):
    let f = fModel.splitFile
    if f.ext == ".nim":
      if not f.name.startsWith("!"):
        echo fModel
        # add result, nnkImportStmt.newTree(newLit(fModel))

  add result, quote do:
    initSystemServices()

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
