# Supranim is a simple MVC-style web framework for building
# fast web applications, REST API microservices and other cool things.
#
# (c) 2021 Supranim | MIT License
#          Made by Humans from OpenPeep
#          Check Supranim Website: https://supranim.com
#          We <3 GitHub: https://github.com/supranim
#

## App Configuration Module
##
## This module handle application configuration at compile-time.
## Basically, Config module is parsing `.env.yml` file at compile-time
## and builds the final binary application based on available config.
import nyml, pkginfo
import std/[macros, tables]
import ../utils

from std/net import Port, getPrimaryIPAddr
from std/nativesockets import Domain
from std/strutils import toLowerAscii, capitalizeAscii, join, indent, strip
from std/os import `/`, dirExists, `/../`, fileExists, normalizedPath

export Port, Domain

type
    RuntimeLoader = object
        imports: seq[string]
        exports: seq[string]

    ServiceType* = enum
        InstanceDefault
        SingletonDefault
        InstancePackage
        SingletonPackage

    ArgT* {.pure.} = enum
        typeString
        typeBool
        typeInt
        typeIdent

    SArg* = ref object
        k*, v*: string
        kind*: ArgT

    Service* = object
        name*: string
        `type`*: ServiceType
        expose*: bool
        case withArgs*: bool
        of true:
            args*: seq[SArg]
        else: discard

    ServiceLoader* = object
        services*: Table[string, Service]

    ServiceConfig = tuple[
        `type`: string
    ]

    StaticConfig = object
        ## A static object (available on compile-time),
        ## that holds the entire application config parsed from `.env.yml`
        ## directly to object using `nyml` and `jsony` packages.
        app: tuple[
            port: int,
            address: string,
            name: string,
            key: string,
            threads: int,
            assets: tuple[source, public: string]
        ]
        services: Table[string, ServiceConfig]
        projectPath: string
            ## Contains the absolute directory path

    AppConfigDefect* = object of CatchableError

var Config* {.compileTime.}: StaticConfig
    ## A singleton of `StaticConfig`, entirely exposed on compile-time.

var configContents {.compileTime.}: string
let
    baseCachePath* {.compileTime.} = getProjectPath() /../ ".cache"
    tkImport {.compileTime.} = "import"
    tkExport {.compileTime.} = "export"

#
# Runtime Loader - Compile-time API
# 
proc add(runtime: var RuntimeLoader, id: string, canExport = false, isDefault = false) {.compileTime.} =
    if isDefault:
        runtime.imports.add("supranim/support/" & id)
    else:
        runtime.imports.add(id)
    if canExport:
        runtime.exports.add(id)

proc getCode*(runtime: var RuntimeLoader): string {.compileTime.} =
    result &= tkImport & "\n"
    result &= indent(runtime.imports.join(",\n"), 4)
    result &= "\n" & tkExport & "\n"
    result &= indent(runtime.exports.join(",\n"), 4)

when not defined inlineConfig:
    static:
        let configPath = getProjectPath() /../ "bin/.env.yml"
        if not fileExists(configPath):
            writeFile(configPath, "")
        configContents = staticRead(configPath)

# 
# Application Config - Compile-time API
#
proc getPort*(config: var StaticConfig): Port {.compileTime.} =
    ## Get application port
    result = Port(config.app.port)

proc getAddress*(config: var StaticConfig): string {.compileTime.} =
    ## Get application address
    result = config.app.address

proc getPublicPathAssets*(config: var StaticConfig): string {.compileTime.} =
    result = normalizedPath(config.app.assets.public)

proc getSourcePathAssets*(config: var StaticConfig): string {.compileTime.} =
    result = normalizedPath(config.projectPath / config.app.assets.source)

proc hasService*(config: var StaticConfig, id: string): bool {.compileTime.} =
    ## Get a specific Service by id
    result = config.services.hasKey(id)

proc getProjectPath*(config: var StaticConfig): string {.compileTime.} =
    result = Config.projectPath

#
# Service Center - API
#
proc getModule(file: string): string {.compileTime.} =
    result = "supranim" / "support" / toLowerAscii(file)

template loadDefaultServices(serviceLoader: var ServiceLoader) =
    # Configure and load default Supranim Services such as
    # Session, Cookie, CSRF, Database
    for serviceName in ["session", "csrf"]:
        serviceLoader.services[serviceName] = Service(
            name: capitalizeAscii(serviceName),
            `type`: SingletonDefault
        )

template loadServiceCenter*() =
    # Configure and load all Application services at compile time.
    var runtimeHandler = RuntimeLoader()
    var serviceLoader = ServiceLoader()

    loadDefaultServices(serviceLoader)
    # echo Config.services
    when requires "tim":
        serviceLoader.services["tim"] = Service(
            name: "Tim",
            `type`: SingletonPackage,
            withArgs: true,
            args: @[
                SArg(k: "source", v: Config.projectPath / "templates"),
                SArg(k: "output", v: Config.projectPath / "storage/templates"),
                SArg(k: "indent", v: "2", kind: ArgT.typeInt),
                SArg(k: "minified", v: "true", kind: ArgT.typeBool),
                SArg(k: "reloader", v: "HttpReloader", kind: ArgT.typeIdent)
            ]
        )

    # Configure and load some Supranim packages
    # when required in the current project application
    when requires "emitter":
        serviceLoader.services["emitter"] = Service(
            name: "Event",
            `type`: SingletonPackage,
            expose: true
        )

    for id, service in pairs(serviceLoader.services):
        if service.`type` in {SingletonDefault, InstanceDefault}:
            result.add(newImport(getModule id))             # import built-in services
        else:
            result.add newImport(id)                        # import third-party services
        if service.expose:
            result.add newExclude(id)

        if service.withArgs:
            var callWithArgs = nnkCall.newTree()
            callWithArgs.add(ident "init")
            callWithArgs.add(ident service.name)
            for arg in service.args:
                var argLit: NimNode
                case arg.kind
                of ArgT.typeBool:
                    argLit = newLit(parseBool(arg.v))
                of ArgT.typeInt:
                    argLit = newLit(parseInt(arg.v))
                of ArgT.typeIdent:
                    argLit = ident(arg.v)
                else:
                    argLit = newLit(arg.v)
                callWithArgs.add(argLit)
            result.add(callWithArgs)
        else:
            result.add(newCall(ident "init", ident service.name))
        if service.`type` in {SingletonDefault, InstanceDefault}:
            runtimeHandler.add(id, true, true)
        else:
            runtimeHandler.add(id, true)
    writeFile(baseCachePath / "runtime.nim", runtimeHandler.getCode())

macro init*(config: var StaticConfig) = 
    ## Parse and validates the YAML config file
    ## `.env.yml` to `Config` object
    if not dirExists(baseCachePath):
        discard staticExec("mkdir " & baseCachePath)
    Config = ymlParser(configContents, StaticConfig)
    Config.projectPath = normalizedPath(getProjectPath() /../ "")
    # TODO find a way to get the local IP on compile time
    when defined unix:
        if Config.app.address.len == 0:
            let localIp = staticExec("ipconfig getifaddr en0")
            Config.app.address = strip(localIp)
