# Supranim is a simple MVC web framework
# for building web apps & microservices in Nim.
#
# (c) 2024 MIT License | Made by Humans from OpenPeeps
# https://supranim.com | https://github.com/supranim

import std/[macros, os, tables, strutils, cpuinfo,
          json, jsonutils, envvars, typeinfo, macrocache]

import pkg/dotenv
import support/[uuid]

from std/net import `$`, Port

export json, jsonutils

type
  Config* = TableRef[string, Any]
  Configs* = TableRef[string, Config]

  Application* = ref object
    key: Uuid
    port: Port
    address: string = "127.0.0.1"
    domain, name: string
    when defined webapp:
      assets: tuple[source, public: string]
    basepath: string
    configs*: TableRef[string, Config]

  AppConfigDefect* = object of CatchableError

const
  basePath* = getProjectPath()
  binPath* = normalizedPath(basePath.parentDir / "bin")
  cachePath* = normalizedPath(basepath.parentDir / ".cache")
  runtimeConfigPath* = cachePath / "runtime" / "config"
  configPath* = basepath / "config"
  controllerPath* = basepath / "controller"
  middlewarePath* = basepath / "middleware"
  databasePath* = basepath / "database"
  storagePath* = basepath / "storage"

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
macro configs*(fields: untyped) =
  ## Parse & collect all configuration files 
  let
    abspath = fields.lineinfoObj.filename
    path = abspath.splitFile
    confname = path.name
    conf = genSym(nskLet, confname)
  var blockStmt = newStmtList()
  expectKind(fields, nnkTableConstr)
  add blockStmt,
    nnkLetSection.newTree(
      newIdentDefs(
        conf,
        newEmptyNode(),
        newCall(ident("Config"))
      ),
    )
  for field in fields:
    expectKind(field, nnkExprColonExpr)
    let allowedFieldTypes = {nnkIdent, nnkStrLit, nnkAccQuoted}
    if field[0].kind notin allowedFieldTypes:
      error("Invalid field key. Expect one of " & $allowedFieldTypes)
    # echo field[1].kind
    # expectKind(field[1], nnkCommand)
    var configValue: NimNode
    let key = field[0].strVal
    let val = field[1]
    let x = genSym(nskVar, "x")
    case field[1].kind
    of nnkStrLit, nnkIntLit, nnkFloatLit, nnkCall:
      add blockStmt,
        nnkVarSection.newTree(
          newIdentDefs(x, newEmptyNode(), field[1])
        ), 
        quote do:
          `conf`[`key`] = toAny(`x`)
    of nnkIdent:
      if val.eqIdent("true") or val.eqIdent("false"):
        # don't know how to determine if is a bool value!
        add blockStmt,
          nnkVarSection.newTree(
            newIdentDefs(x, newEmptyNode(), newLit(val.strVal == "true"))
          ), 
          quote do:
            `conf`[`key`] = toAny(`x`)
    else: discard
  # expose configuration at compile-time using macrocache table
  # staticConfig[confname] = conf
  add blockStmt, quote do:
    # expose configuration files at runtime
    # via `app.config("filename", "key")`
    app.configs[`confname`] = `conf`
  result = newStmtList().add(
    nnkBlockStmt.newTree(
      newEmptyNode(),
      blockStmt
    )
  )
  # echo result.repr

proc config*(app: Application, confname, key: string): Any =
  if likely(app.configs.hasKey(confname)):
    if likely(app.configs[confname].hasKey(key)):
      return app.configs[confname][key]

macro singletons*(x: untyped): untyped =
  var y = newStmtList()
  y.add(
    nnkImportStmt.newTree(
      nnkInfix.newTree(
        ident("/"),
        ident("supranim"),
        nnkBracket.newTree(
          ident("application")
        )
      )
    )
  )
  y.add(x)
  writeFile(cachePath / "runtime.nim", y.repr)
  # autoload /{project}./cache/runtime.nim
  result = newStmtList()
  result.add(
    nnkImportStmt.newTree(
      nnkInfix.newTree(
        ident("/"),
        ident("supranim"),
        nnkBracket.newTree(
          ident("runtime"),
        )
      ),
    )
  )

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

macro init*(x) =
  ## Initializes the Application
  expectKind(x, nnkLetSection)
  expectKind(x[0][2], nnkEmpty)
  result = newStmtList()
  x[0][2] = newCall(ident "Application")
  add result, x
  add result, quote do:
    app.configs = Configs()
  if not dirExists(cachePath):
    # creates `.cache` directory inside working project path.
    # here we'll store generated nim files that can be
    # called via `supranim/runtime` or `supranim/facade`
    createDir(cachePath)
  # if not dirExists(runtimeConfigPath):
    # createDir(runtimeConfigPath)

  var runtimeConfigImports = newStmtList()
  var runtimeConfigExports = newNimNode(nnkExportStmt)
  info "Parse Configuration files:", 2
  add result,
    nnkImportStmt.newTree(
      nnkInfix.newTree(
        ident("/"),
        ident("std"),
        nnkBracket.newTree(
          ident("tables"),
          ident("envvars"),
          ident("typeinfo")
        )
      ),
      ident("dotenv")
    )
  add result, quote do:
    dotenv.load(normalizedPath(`basePath` / ".."), ".env")
  for filePath in walkDirRec(configPath):
    # read compile-time /config/*.nims
    if filePath.endsWith(".nims"):
      let confname = filePath.splitFile.name
      info "- " & confname, 2
      add result, nnkIncludeStmt.newTree(newLit(filePath))

  # var runtimeConfig = newStmtList()
  # runtimeConfig.add(runtimeConfigImports)
  # runtimeConfig.add(runtimeConfigExports)
  # add result, nnkImportStmt.newTree(
  #   nnkInfix.newTree(
  #     ident("/"),
  #     ident("supranim"),
  #     ident("runtime")
  #   )
  # )
  # for conf in runtimeConfig[0]:
  #   let fname = conf[0].strVal.splitFile
  #   let configName = genConfigName(fname.name)
  #   let configPath = runtimeConfigPath / fname.name
  #   add result, quote do:
  #     writeFile(`configPath`, toFlatty(`configName`))

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
        add result, nnkImportStmt.newTree(newLit(fModel))


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
