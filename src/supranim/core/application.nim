import pkg/[pkginfo, nyml]
import std/[macros, os, tables, strutils, cpuinfo, compilesettings]
import supranim/[utils, finder, support/uuid]

when defined webapp:
  import ./assets

from std/nativesockets import Domain
from std/net import `$`, Port
# from std/logging import Logger

type
  AppDirectory* = enum
    ## Known Supranim application paths
    Config              = "config"
    Controller          = "controller"
    Database            = "database"
    PluginsDirectory    = "../storage/plugins"
    DatabaseMigrations  = "database/migrations"
    DatabaseModels      = "database/models"
    DatabaseSeeds       = "database/seeds"
    EventListeners      = "events/listeners"
    EventSchedules      = "events/schedules"
    I18n                = "i18n"
    Middlewares         = "middlewares"

  FacadeId = distinct string
  Facade* = ref object
    name*: string

  Facades* = ref object
    services: TableRef[FacadeId, Facade]
  
  DBConfig = ref object 
    driver: string
    port: int
    host: string
    prefix: string
    name: string
    user: string
    password: string

  Configurator = ref object
    port: Port
    address, name: string
    key: Uuid
    threads: int
    assets: tuple[source, public: string]
    views: string
    useLAN: bool
    # database: DBConfig
    projectPath: string
    facades: Facades

  ConfigDefect* = object of CatchableError

  Application* {.acyclic.} = ref object
    state*: bool
    config: Configurator

  AppDefect* = object of CatchableError

var
  doc* {.compileTime.}: nyml.Document
  Configs*: Configurator
  App* = Application()

let
  dirProjectPath {.compileTime.} = normalizedPath(getProjectPath() /../ "") 
  dirCachePath* {.compileTime.} = dirProjectPath / ".cache"
  fileEnvPath {.compileTime.} = dirProjectPath / "bin/.env.yml"
  tkImport {.compileTime.} = "import"
  tkExport {.compileTime.} = "export"

#
# Facade API
#
# proc newFacade(facades: var FacadeLoader, id: FacadeId) {.compileTime.} =

# dumpAstGen:
  # Config.app.port = Port(doc.get("app.port").getInt)

proc initConfigurator*(): Configurator =
  Configurator()

proc getPort*(config: var Document): Port {.compileTime.} =
  ## Get application port
  result = Port(config.get("port").getInt)

proc getAddress*(config: var Document): string {.compileTime.} =
  ## Get application address
  result = config.get("address").getStr

proc getPublicPathAssets*(config: var Document): string {.compileTime.} =
  result = normalizedPath(config.get("app.assets.public").getStr)

proc getSourcePathAssets*(config: var Document): string {.compileTime.} =
  result = normalizedPath(dirProjectPath / config.get("app.assets.source").getStr)

proc getAppDir*(appDir: AppDirectory, suffix: varargs[string] = ""): string {.compileTime.} =
  result = getProjectPath() & "/" & $appDir
  if suffix.len != 0:
    result &= "/" & suffix.join("/")

proc getThreads*(app: Application): int =
  result = app.config.threads

macro path*(appDir: AppDirectory, append: static string = ""): untyped =
  var getPath: string = getProjectPath() & "/" & $appDir.getImpl
  if append.len != 0:
      getPath &= "/" & append
  result = newStmtList()
  result.add quote do:
    `getPath`

proc newConfig*(stmts: NimNode) {.compileTime.} =
  ## Create a new Configuration instance at compile time.
  if not dirExists(dirCachePath):
    discard staticExec("mkdir " & dirCachePath) # Create `.cache` directory
  if not fileExists(fileEnvPath):
    writeFile(fileEnvPath, ymlConfigSample)

  let configContents = staticRead(fileEnvPath)
  doc = yaml(configContents).toJson()
  stmts.add(
    newAssignment(
      ident("Configs"),
      newCall(ident "initConfigurator")
    )
  )
  let appKey = doc.get("app.key")
  if appKey != nil:
    try:
      discard uuid4(appKey.getStr)
    except UUIDError:
      error("Invalid app key. Generate a new one using SUP cli")
  else:
    warning("Missing app key in env file. Generate one using SUP cli.")

  var appAssignments = [
    ("port", newCall(ident "Port", newLit doc.get("app.port", %* 9933).getInt)),
    ("address", newLit doc.get("app.address", %* "127.0.0.1").getStr),
    ("useLAN", newLit doc.get("app.useLAN", %* false).getBool),
    ("name", newLit doc.get("app.name", %* "My Supranim").getStr),
    ("threads", newLit doc.get("app.threads", %* 1).getInt),
  ]

  if appAssignments[2][1].boolVal:
    var localIp: string
    when defined macos:
      localIp = staticExec("hostname | cut -d' ' -f1")
    when defined linux:
      localIp = staticExec("hostname -I | cut -d' ' -f1")
    appAssignments[1][1] = newLit strip(localIp)

  var appAssetsPaths = [
    ("source", newLit doc.get("app.assets.source").getStr),
    ("source", newLit doc.get("app.assets.public").getStr),
  ]
  let configsAppField = ident "Configs" 
  for assign in appAssignments:
    stmts.add(
      newAssignment(
        newDotExpr(
          configsAppField,
          ident assign[0]
        ),
        assign[1]
      )
    )
  for assign in appAssetsPaths:
    stmts.add(
      newAssignment(
        newDotExpr(
          newDotExpr(
            configsAppField,
            ident "assets"
          ),
          ident assign[0]
        ),
        assign[1]
      )
    )

  let facadeFile = getAppDir(Config, "facade.yml")
  if fileExists(facadeFile):
    var
      initFacades, initFrameworkFacades = newStmtList()
      imports, exports: seq[string]
      frameworkImports = newNimNode(nnkBracket)
    initFrameworkFacades.add(
      newCommentStmtNode("Initialize facades\n" & "Auto-generated at compile-time ($1@$2)" % [CompileDate, CompileTime])
    )
    let services = yaml(staticRead(facadeFile)).toJson
    proc getInitializer(initFacade: var NimNode, pName: string, p: JsonNode) =
      var initFn: NimNode
      if p.hasKey("initializer"):
        initFn = ident(p["initializer"].getStr)
      else:
        initFn = ident("init")
      initFacade.add newDotExpr(ident pName, initFn)
      if p.hasKey("ident"):
        initFacade.add ident p["ident"].getStr
      else:
        initFacade.add ident pName.capitalizeAscii

    for service in services.get():
      for pName, p in service.pairs(): 
        if pName.startsWith("supranim"):
          let pIdent = pName[9..^1]
          frameworkImports.add ident(pIdent)
          exports.add pIdent
          var initFacade = nnkCall.newTree()
          initFacade.getInitializer(pIdent, p)
          initFrameworkFacades.add(initFacade)
        elif requires pName:
          imports.add pName
          exports.add pName
          initFacades.add(
            newCommentStmtNode(
              pkg(pName).getName & indent("(" & $pkg(pName).getVersion & ")", 1)
            )
          )
          var initFacade = nnkCall.newTree()
          initFacade.getInitializer(pName, p)
          if p.hasKey("params"):
            for arg, value in p["params"].pairs():
              var lit: NimNode
              case value.kind
                of JString:
                  lit = newLit(value.getStr)
                of JInt:
                  lit = newLit(value.getInt)
                of JBool:
                  lit = newLit(value.getBool)
                of JFloat:
                  lit = newLit(value.getFloat)
                else: discard
              initFacade.add(nnkExprEqExpr.newTree(ident(arg), lit))
          initFacades.add(initFacade)
        else:
          warning("Unused facade `$1`" % [pName])
    var
      exportsNode = newExport(exports, "Exports available services")
      importNode = newImport(imports)
      importSupportNode = 
        nnkImportStmt.newTree(
          nnkInfix.newTree(
            ident "/",
            nnkInfix.newTree(
              ident "/",
              ident "supranim",
              ident "support"
            ),
            frameworkImports
          )
        )
    let facadeCode =
      importSupportNode.repr & "\n" &
      importNode.repr & "\n" &
      exportsNode.repr & "\n"
    writeFile(dirCachePath / "facade.nim", facadeCode)
    stmts.add newImport("supranim/facade")
    stmts.add initFrameworkFacades
    stmts.add initFacades
    # echo stmts.repr
  # StaticConfig.projectPath = dirProjectPath
  # StaticConfig.app.key = $uuid4()
  # stmts.add quote do:
    # Configs.app.key = uuid4()

macro init*(app: Application, autoIncludeRoutes: static bool = true) =
  ## Supranim application initializer.
  result = newStmtList()
  newConfig(result)
  result.add quote do:
    `app`.config = Configs
  when defined webapp:
    when not defined release:
      let publicDirPath = doc.getPublicPathAssets
      let sourceDirPath = doc.getSourcePathAssets
      result.add quote do:
        `app`.state = true
        let publicDir = `publicDirPath`
        var sourceDir = `sourceDirPath`
        if publicDir.len == 0 or sourceDir.len == 0:
          raise newException(AppDefect,
            "Invalid project structure. Missing `public` or `source` directories")
        Assets.init(sourceDir, publicDir)
  # loadServiceCenter()
  when requires "emitter":
    let appEvents = staticFinder(SearchFiles, getAppDir(EventListeners))
    for appEventFile in appEvents:
      result.add(newInclude(appEventFile))

  result.add newImport("supranim/router")
  if autoIncludeRoutes:
    result.add newInclude(getProjectPath() / "routes.nim")

macro printBootStatus*() =
  result = newStmtList()
  var compileOpts: seq[string]
  let NO = "no"
  let YES = "yes"
  result.add quote do:
    echo "----------------- ⚡️ -----------------"
    echo("👌 Up & Running on http://127.0.0.1:9933")

  when compileOption("opt", "size"):
    compileOpts.add("Size Optimization")
  when compileOption("opt", "speed"):
    compileOpts.add("Speed Optimization")
  
  when compileOption("gc", "arc"):
    compileOpts.add("Memory Management:" & indent("ARC", 1))
  when compileOption("gc", "orc"):
    compileOpts.add("Memory Management:" & indent("ORC", 1))

  # when compileOption("threads"):
  #     compileOpts.add("Threads:" & indent("$1", 1))

  # echo querySetting(SingleValueSetting.compileOptions)

  for optLabel in compileOpts:
    result.add(
      nnkCommand.newTree(
        ident "echo",
        newCall(
          ident "indent",
          nnkInfix.newTree(
            ident "&",
            newLit "✓ ",
            newLit optLabel
          ),
          newLit(2)
        )
      )
    )
  when requires "emitter":
    result.add quote do:
      Event.emit("system.boot.services")

export strutils.indent