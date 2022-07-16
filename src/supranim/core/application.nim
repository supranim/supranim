# Supranim is a simple MVC-style web framework for building
# fast web applications, REST API microservices and other cool things.
#
# (c) 2021 Supranim is released under MIT License
#          Made by Humans from OpenPeep
#          https://supranim.com | https://github.com/supranim

import std/tables
import pkginfo, nyml, emitter

import std/macros
import ./config/assets
import ./supplier

from std/nativesockets import Domain
from std/net import Port
from std/logging import Logger
from std/strutils import toUpperAscii, indent, split
from std/os import getCurrentDir, putEnv, getEnv, fileExists,
                    getAppDir, normalizePath, walkDirRec

export Port
export nyml.get, nyml.getInt, nyml.getStr, nyml.getBool

const SECURE_PROTOCOL = "https"
const UNSECURE_PROTOCOL = "http"
const NO = "no"
const YES = "yes"

type
    AppType* = enum
        ## Whther is a Web or a RESTful app
        WebApp, RESTful

    AppDirectory* = enum
        ## Known Supranim application paths
        Config = "configs"
        Controller = "controller"
        Database = "database"
        DatabaseMigrations = "database/migrations"
        DatabaseModels = "database/models"
        DatabaseSeeds = "database/seeds"
        Events = "events"
        EventListeners = "events/listeners"
        EventSchedules = "events/schedules"
        I18n = "i18n"
        Middlewares = "middlewares"

    DBDriver* = enum
        PGSQL, MYSQL, SQLITE

    DBConnection = ref object
        port: Port
        driver: DBDriver
        address: Domain
        name: string
        username: string
        password: string

    DB = ref object
        main: DBConnection
        secondary: seq[DBConnection]

    Application* = object
        appType: AppType
        port: Port
            ## Specify a port or let retrieve one automatically
        address: string
            ## Specify a local IP address
        domain: Domain
            ## Domain used for application runtime
        ssl: bool
            ## Boot in SSL mode (requires HTTPS Certificate)
        threads: int
            ## Boot Supranim on a specific number of threads
        database: DB
            ## Holds all database credentials
        views: string
            ## Path to Views source directory
        recyclable: bool
            ## Whether to reuse current port or not
        loggers: seq[Logger]
            ## Loggers used in background by current application instance
        configs: Document
            ## Holds Document representation of ``.env.yml`` configuration file
        isInitialized: bool

    ApplicationDefect* = object of CatchableError

const yamlEnvFile = ".env.yml"

var App* {.threadvar.}: Application
App = Application()

when not defined inlineConfig:
    const ymlConfigContents = staticRead(getProjectPath() & "/../bin/" & yamlEnvFile)

proc parseEnvFile(configContents: string): Document =
    # Private procedure for parsing and validating the
    # ``.env.yml`` configuration file.
    # 
    # The YML contents is parsed with Nyml library, for more details
    # related to Nyml limitations and YAML syntax supported by Nyml
    # check official repository: https://github.com/openpeep/nyml
    var yml = Nyml.init(contents = configContents)
    result = yml.toJson()

method config*[A: Application](app: A): Document =
    result = app.configs

proc init*(port = Port(3399), ssl = false, threads = 1, inlineConfigStr: string = ""): Application =
    ## Main procedure for initializing your Supranim Application.
    if App.isInitialized:
        raise newException(ApplicationDefect, "Application has already been initialized once")
    App.configs =
        when not defined(inlineConfig):
            # Load app config from a .env.yml file
            parseEnvFile(ymlConfigContents)
        else:
            # load app config from `inlineConfigStr`. Useful for
            # embedding Supranim in other libraries, for example
            # Chocotone https://github.com/chocotone
            parseEnvFile(inlineConfigStr)

    let publicDir = App.config.get("app.assets.public").getStr
    var sourceDir = App.config.get("app.assets.source").getStr
    if publicDir.len != 0 and sourceDir.len != 0:
        # when not defined(release):
        sourceDir = getAppDir() & "/" & sourceDir
        normalizePath(sourceDir)
        Assets.init(sourceDir, publicDir)
    else:
        App.appType = RESTful

    App.address = App.config.get("app.address").getStr
    App.domain = Domain.AF_INET
    App.port = Port(App.config.get("app.port").getInt)
    App.threads = App.config.get("app.threads").getInt
    App.recyclable = true
    App.isInitialized = true
    result = App

# proc loadEventListeners() {.compileTime.} = 
#     ## Load application event listeners (if any)
#     for files in Finder.files():
#         echo file.getFileName()
#         echo file.getFileSize()

# dumpAstGen:
#     Event.emit("system.boot.services")

macro init*[A: Application](app: var A) =
    ## Initialize Supranim application based on current
    ## configuration and available services.
    var yml = Nyml.init(contents = ymlConfigContents)
    let doc: Document = yml.toJson()
    result = newStmtList()
    if doc.get().hasKey("services"):
        let services = doc.get("services")
        # TODO
        # for id, conf in pairs(services):
            # result.add(nnkImportStmt.newTree(ident id))
            # var singleton = split(conf["singleton"].getStr, ':')
            # let singletonIdent = singleton[0]
            # let singletonObject = singleton[1]
            # var callable = nnkCall.newTree()
            # callable.add(ident "init")
            # callable.add(ident singletonObject)
            # if conf.hasKey("settings"):
            #     for pId, pVal in pairs(conf["settings"]):
            #         case pVal.kind:
            #         of JString:
            #             callable.add(
            #                 nnkExprEqExpr.newTree(
            #                     ident pId,
            #                     newLit pVal.getStr
            #                 )
            #             )
            #         of JBool:
            #             callable.add(
            #                 nnkExprEqExpr.newTree(
            #                     ident pId,
            #                     newLit pVal.getBool
            #                 )
            #             )
            #         of JInt:
            #             callable.add(
            #                 nnkExprEqExpr.newTree(
            #                     ident pId,
            #                     newLit pVal.getInt
            #                 )
            #             )
            #         else: discard # TODO
            #     result.add(
            #         nnkVarSection.newTree(
            #             nnkIdentDefs.newTree(
            #                 nnkPostfix.newTree(
            #                     ident "*",
            #                     ident singletonIdent
            #                 ),
            #                 newEmptyNode(),
            #                 callable
            #             )
            #         )
            #     )
            # else:
            #     result.add(
            #         nnkVarSection.newTree(
            #             nnkIdentDefs.newTree(
            #                 nnkPostfix.newTree(
            #                     ident "*",
            #                     ident singletonIdent
            #                 ),
            #                 newEmptyNode(),
            #                 callable
            #             )
            #         )
            #     )
    # Include application routes.nim file
    result.add(
        nnkIncludeStmt.newTree(
            ident getProjectPath() & "/" & "routes.nim"
        )
    )

    result.add(
        nnkCall.newTree(
            nnkDotExpr.newTree(
                newIdentNode("Event"),
                newIdentNode("emit")
            ),
            newLit("system.router.load")
        )
    )

    result.add quote do:
        discard init(threads = 1)

template start*[A: Application](app: var A) =
    ## Boot Supranim application
    app.startServer()

method getAppType*[A: Application](app: A): AppType =
    result = app.appType

method hasTemplates*[A: Application](app: A): bool =
    ## Determine if current app has Tim Engine templates
    ## TODO
    result = false

method getAddress*[A: Application](app: A, path = ""): string =
    ## Get the current local address
    result = app.address
    if path.len != 0: add result, "/" & path

method getPort*[A: Application](app: A): Port =
    ## Get the current Port
    result = app.port

method hasSSL*[A: Application](app: A): bool =
    ## Determine if ssl is turned on
    result = app.ssl

method hasDatabase*[A: Application](app: A): bool =
    ## Determine if application has a database attached
    # result = app.database.main != nil
    result = app.database != nil

method hasMultiDatabase*[A: Application](app: A): bool =
    ## Determine if application has multi databases attached
    if app.database != nil:
        result = app.database.secondary.len != 0

method isMultithreading*[A: Application](app: A): bool =
    ## Determine if application runs on multiple threads
    result = app.threads notin {0, 1}

method getThreads*[A: Application](app: A): int =
    ## Get the number of available threads
    result = app.threads

method getLoggers*[A: Application](app: A): seq[Logger] =
    ## Retrieve all logger instances
    result = app.loggers

method getDomain*[A: Application](app: A): Domain =
    ## Retrieve Supranim domain instance
    result = app.domain

method url*[A: Application](app: A, path: string): string =
    ## Create an application URL
    add result, if app.hasSSL(): SECURE_PROTOCOL else: UNSECURE_PROTOCOL
    add result, "://" & app.getAddress() & ":" & $(App.config.get("app.port").getInt) & "/" & path

method getConfig*[A: Application](app: A, key: string): JsonNode = 
    ## Return a ``JsonNode`` value from current Supranim configuration
    ## by using dot annotations.
    result = App.config.get(key)

proc getProjectDirectory(path: string, getAppPath = false): string =
    ## Temporary to create a compatiblity for Chocotone Library
    ## in order to handle static files in a Chocotone desktop native app
    ## TODO:
    ## Supranim should have various options for handling static assets
    ## 1. CSS/JS assets bundled directly in binary app
    ## 2. Load CSS/JS assets on request externally from an absolute path
    ## Also, Supranim should support with Tim Engine
    result = if getAppPath == true: getAppDir() else: getCurrentDir()
    result = result & path

method getViewContent*[A: Application](app: var A, key: string, layout = "base"): string =
    ## Retrieve contents of a specific view by view id.
    ## TODO, implement in a separate logic, integrate with Tim Engine
    let pathView = getProjectDirectory("/assets/" & key & ".html", true)
    if fileExists(pathView):
        result = readFile(pathView)

method isRecyclable*[A: Application](app: A): bool =
    ## Determine if application instance can reuse the same Port
    result = app.recyclable

method printBootStatus*[A: Application](app: A) =
    ## Public procedure used to print various informations related to current application instance
    echo "----------------- ⚡️ -----------------"
    echo("👌 Up & Running on http://", app.getAddress&":"& $app.getPort)

    var defaultCompileOptions: seq[string]

    # Compiling with ``-opt:size``
    when compileOption("opt", "size"):
        defaultCompileOptions.add("Compiled with Size Optimization")
    
    # Compiling for a ``-d:release`` version
    when defined(release):
        defaultCompileOptions.add("Release mode: Production")
    else:
        defaultCompileOptions.add("Release mode: Development")
    
    # Compiling application in multithreading mode
    when compileOption("threads"):
        defaultCompileOptions.add("Multi-threading: " & YES & " (threads: " & $app.getThreads & ")")
    else:
        defaultCompileOptions.add("Multi-threading: " & NO)

    if Assets.exists():
        # Web apps can serve Static Assets
        defaultCompileOptions.add("Static Assets Handler: " & YES)

    # Compiling with Template Engine or use Supranim asa REST API service
    if app.hasTemplates():
        defaultCompileOptions.add("Template Engine: " & YES)

    # Compiling with DatabaseService
    if app.hasDatabase():
        defaultCompileOptions.add("Database:" & YES)

    for compileOptionLabel in defaultCompileOptions:
        echo indent("✓ " & compileOptionLabel, 2)
    
    # Emit all listeners registered on `system.boot.services` event
    Event.emit("system.boot.services")
