import nyml

from std/nativesockets import Domain
from std/net import Port
from std/logging import Logger
from std/os import getCurrentDir, putEnv, getEnv, fileExists
from std/strutils import toUpperAscii

export Port

include supranim/db

type
    AssetsTuple = ref tuple[source, public: string]

    Application* = object
        port: Port                  ## Specify a port or let retrieve one automatically
        address: string             ## Specify a local IP address
        domain: Domain
        ssl: bool                   ## Boot in SSL mode (requires HTTPS Certificate)
        threads: int                ## Boot Supranim on a specific number of threads
        database: DBConfig
        assets: AssetsTuple
        views: string               ## Path to Views source directory
        recyclable: bool            ## Whether to reuse current port or not
        loggers: seq[Logger]

const yamlEnvFile = ".env.yml"

var App* {.threadvar.}: Application
App = Application()

proc parseEnvFile(envPath: string): Document =
    ## Parse and validate .env.yml configuration file
    var yml = Nyml.init(contents = readFile(envPath))
    result = yml.toJson()

proc init*(port = Port(3399), address = "localhost", ssl = false, threads = 1): Application =
    ## Initialize Supranim Application
    let doc: Document = parseEnvFile(envPath = getCurrentDir() & "/bin/" & yamlEnvFile)
    ## Set DB Environment credentials
    for dbEnv in @["host", "prefix", "name", "user", "password"]:
        putEnv("DB_" & toUpperAscii(dbEnv), doc.get("database.main." & dbEnv).getStr)
    # testDb()
    App.address = address
    App.domain = Domain.AF_INET
    App.port = Port(doc.get("app.port").getInt)
    App.threads = doc.get("app.threads").getInt
    App.recyclable = true
    result = App

proc getAddress*[A: Application](app: A): string {.inline.}  =
    ## Get the local address
    result = app.address

proc getPort*[A: Application](app: A): Port {.inline.} =
    ## Get the current Port
    result = app.port

proc hasSSL*[A: Application](app: A): bool {.inline.}  =
    ## Determine if ssl is turned on
    result = app.ssl

proc hasDatabase*[A: Application](app: A): bool {.inline.} =
    ## Determine if application has a database attached
    result = app.database != nil    

proc hasMultiDatabase*[A: Application](app: A): bool {.inline.} =
    ## Determine if application has multi databases attached
    result = app.secondary.len != 0

proc isMultithreading*[A: Application](app: A): bool {.inline.}  =
    ## Determine if application runs on multiple threads
    result = app.threads notin {0, 1}

proc getThreads*[A: Application](app: A): int {.inline.} =
    ## Get number of available threads
    result = app.threads

proc getLoggers*[A: Application](app: A): seq[Logger] =
    ## Retrieve all logger instances
    result = app.loggers

proc getDomain*[A: Application](app: A): Domain =
    ## Retrieve Supranim domain instance
    result = app.domain

proc getViewContent*(app: var Application, key: string, layout = "base"): string =
    ## Retrieve contents of a specific view by view id.
    let pathView = getCurrentDir() & "/assets/" & key & ".html"
    if fileExists(pathView):
        result = readFile(pathView)

proc isRecyclable*[A: Application](app: A): bool =
    ## Determine if current application Port can be reused
    result = app.recyclable

proc printBootStatus*[A: Application](app: A) =
    ## Print boot status of the current application instance
    echo "----------------- ⚡️ -----------------"
    echo("👌 Up & Running on http://", app.getAddress&":"& $app.getPort)
    
    var defaultCompileOptions: seq[string]
    when compileOption("opt", "size"):
        defaultCompileOptions.add("Compiled with Size Optimization")
    when defined(release):
        defaultCompileOptions.add("Release mode: Production")
    else:
        defaultCompileOptions.add("Release mode: Development")
    when compileOption("threads"):
        defaultCompileOptions.add("Multi-threading: true (threads: " & $app.getThreads & ")")
    else:
        defaultCompileOptions.add("Multi-threading: false")

    for compileOptionLabel in defaultCompileOptions:
        echo "✓ " & compileOptionLabel

    # echo "✓ Static Assets Proxy: Yes"
    # echo "✓ Release mode: Development"
    # echo "--------- Service Providers ----------"
    # for loadedService in loadedServices:
    #     echo("✓ ", loadedService)
