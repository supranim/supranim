# Supranim is a simple MVC-style web framework for building
# fast web applications, REST API microservices and other cool things.
#
# (c) 2021 Supranim is released under MIT License
#          George Lemon | Made by Humans from OpenPeep
#          https://supranim.com   |    https://github.com/supranim

import nyml
import std/tables

when defined(webapp):
    import emitter

import std/macros
from std/nativesockets import Domain
from std/net import Port
from std/logging import Logger
from std/os import getCurrentDir, putEnv, getEnv, fileExists, getAppDir, normalizePath
from std/strutils import toUpperAscii, indent, split

import ./config/assets
export Port
export assets
export nyml.get, nyml.getInt, nyml.getStr, nyml.getBool

const SECURE_PROTOCOL = "https"
const UNSECURE_PROTOCOL = "http"
const NO = "no"
const YES = "yes"

type
    AppType* = enum
        WebApp, RESTful

    Application* = object
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
        # database: DBConfig
        database: bool
            ## PostgreSQL Database credentials
        assets: Assets
            ## Hold source and public paths for retriving and rendering static assets
        views: string
            ## Path to Views source directory
        recyclable: bool
            ## Whether to reuse current port or not
        loggers: seq[Logger]
            ## Loggers used in background by current application instance
        config*: Document
            ## Holds Document representation of ``.env.yml`` configuration file
        appType: AppType

const yamlEnvFile = ".env.yml"

var App* {.threadvar.}: Application
App = Application()

when not defined(inlineConfig):
    const ymlConfigContents = staticRead(getProjectPath() & "/../bin/" & yamlEnvFile)

proc parseEnvFile(configContents: string): Document =
    # Private procedure for parsing and validating the ``.env.yml`` configuration file.
    # The YML contents is parsed with Nyml library, for more details
    # related to Nyml limitations and YAML syntax supported by Nyml
    # check official repository: https://github.com/openpeep/nyml
    var yml = Nyml.init(contents = configContents)
    result = yml.toJson()

proc init*(port = Port(3399), ssl = false, threads = 1, inlineConfigStr: string = ""): Application =
    ## Main procedure for initializing your Supranim Application.
    App.config =
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
        sourceDir = getAppDir() & "/" & sourceDir
        normalizePath(sourceDir)
        App.assets = Assets.init(sourceDir, publicDir)
    else:
        App.appType = RESTful

    App.address = App.config.get("app.address").getStr
    App.domain = Domain.AF_INET
    App.port = Port(App.config.get("app.port").getInt)
    App.threads = App.config.get("app.threads").getInt
    App.recyclable = true
    result = App

dumpAstGen:
    var Tim* = init(TimEngine, source = "a", output = "b")

macro init*[A: Application](app: var A) =
    ## Initialize Supranim application based on current
    ## configuration and available services.
    var yml = Nyml.init(contents = ymlConfigContents)
    let doc: Document = yml.toJson()
    let services = doc.get("services")
    result = newStmtList()
    
    # iterate over available services
    for id, conf in pairs(services):
        var singleton = split(conf["singleton"].getStr, ':')
        let singletonIdent = singleton[0]
        let singletonObject = singleton[1]
        result.add(nnkImportStmt.newTree(ident id))
        var callable = nnkCall.newTree()
        callable.add(ident "init")
        callable.add(ident singletonObject)
        if conf.hasKey("settings"):
            for pId, pVal in pairs(conf["settings"]):
                case pVal.kind:
                of JString:
                    callable.add(
                        nnkExprEqExpr.newTree(
                            ident pId,
                            newLit pVal.getStr
                        )
                    )
                of JBool:
                    callable.add(
                        nnkExprEqExpr.newTree(
                            ident pId,
                            newLit pVal.getBool
                        )
                    )
                of JInt:
                    callable.add(
                        nnkExprEqExpr.newTree(
                            ident pId,
                            newLit pVal.getInt
                        )
                    )
                else: discard # TODO
            result.add(
                nnkVarSection.newTree(
                    nnkIdentDefs.newTree(
                        nnkPostfix.newTree(
                            ident "*",
                            ident singletonIdent
                        ),
                        newEmptyNode(),
                        callable
                    )
                )
            )
    result.add quote do:
        var supserver = init(threads = 1)
        supserver.start()

proc getAppType*[A: Application](app: A): AppType =
    result = app.appType

proc hasAssets*[A: Application](app: A): bool =
    ## Determine if current Supranim application has an Assets instance
    result = app.assets != nil

proc hasTemplates*[A: Application](app: A): bool =
    ## Determine if current Supranim application has enabled the template engine
    result = false

proc instance*[A: Application, B: typedesc[Assets]](app: A, assets: B): Assets =
    ## Procedure for returning the Assets instance from current Application
    result = app.assets

proc getAddress*[A: Application](app: A, path = ""): string {.inline.}  =
    ## Get the current local address
    result = app.address
    if path.len != 0: add result, "/" & path

proc getPort*[A: Application](app: A): Port {.inline.} =
    ## Get the current Port
    result = app.port

proc hasSSL*[A: Application](app: A): bool {.inline.}  =
    ## Determine if ssl is turned on
    result = app.ssl

proc hasDatabase*[A: Application](app: A): bool {.inline.} =
    ## Determine if application has a database attached
    # result = app.database.main != nil
    result = false

proc hasMultiDatabase*[A: Application](app: A): bool {.inline.} =
    ## Determine if application has multi databases attached
    # result = app.secondary.len != 0
    result = false

proc isMultithreading*[A: Application](app: A): bool {.inline.}  =
    ## Determine if application runs on multiple threads
    result = app.threads notin {0, 1}

proc getThreads*[A: Application](app: A): int {.inline.} =
    ## Get the number of available threads
    result = app.threads

proc getLoggers*[A: Application](app: A): seq[Logger] =
    ## Retrieve all logger instances
    result = app.loggers

proc getDomain*[A: Application](app: A): Domain =
    ## Retrieve Supranim domain instance
    result = app.domain

proc url*[A: Application](app: A, path: string): string =
    ## Create an application URL
    add result, if app.hasSSL(): SECURE_PROTOCOL else: UNSECURE_PROTOCOL
    add result, "://" & app.getAddress() & ":" & $(App.config.get("app.port").getInt) & "/" & path

proc getConfig*[A: Application](app: A, key: string): JsonNode = 
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

proc getViewContent*(app: var Application, key: string, layout = "base"): string =
    ## Retrieve contents of a specific view by view id.
    ## TODO, implement in a separate logic, integrate with Tim Engine
    let pathView = getProjectDirectory("/assets/" & key & ".html", true)
    if fileExists(pathView):
        result = readFile(pathView)

proc isRecyclable*[A: Application](app: A): bool =
    ## Determine if application instance can reuse the same Port
    result = app.recyclable

proc printBootStatus*[A: Application](app: A) =
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
    
    # Compiling with static assets handler enabled or use Supranim as a REST API service
    if app.hasAssets():
        defaultCompileOptions.add("Static Assets Handler: " & YES)

    # Compiling with Template Engine or use Supranim asa REST API service
    if app.hasTemplates():
        defaultCompileOptions.add("Template Engine: " & YES)

    # Compiling with DatabaseService
    if app.hasDatabase():
        defaultCompileOptions.add("Database:" & YES)

    for compileOptionLabel in defaultCompileOptions:
        echo indent("✓ " & compileOptionLabel, 2)
    
    when defined(webapp):
        Event.emit("system.boot.services")

    # echo "--------- Service Providers ----------"
    # for loadedService in loadedServices:
    #     echo("✓ ", loadedService)
