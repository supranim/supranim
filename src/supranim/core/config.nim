# Supranim is a simple MVC-style web framework for building
# fast web applications, REST API microservices and other cool things.
#
# (c) 2021 Supranim is released under MIT License
#          George Lemon | Made by Humans from OpenPeep
#          https://supranim.com   |    https://github.com/supranim

import nyml, pkginfo
import std/[macros, tables]
import ../utils

from std/net import Port
from std/nativesockets import Domain
from std/strutils import toLowerAscii, capitalizeAscii, join, indent
from std/os import `/`, dirExists, `/../`, fileExists

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

    ArgType* = enum
        ArgTypeString
        ArgTypeBool
        ArgTypeInt

    SArg* = ref object
        k*, v*: string
        kind*: ArgType

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
        services: Table[string, string]

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
    result = config.app.assets.public

proc getSourcePathAssets*(config: var StaticConfig): string {.compileTime.} =
    result = config.app.assets.source

proc hasService*(config: var StaticConfig, id: string): bool {.compileTime.} =
    ## Get a specific Service by id
    result = config.services.hasKey(id)


#
# Service Center - API
#
proc getModule(file: string): string {.compileTime.} =
    result = "supranim" / "support" / toLowerAscii(file)

template loadDefaultServices(serviceLoader: var ServiceLoader) =
    for serviceName in ["session", "csrf"]:
        serviceLoader.services[serviceName] = Service(
            name: capitalizeAscii(serviceName),
            `type`: SingletonDefault
        )

template loadServiceCenter*() =
    var runtimeHandler = RuntimeLoader()
    var serviceLoader = ServiceLoader()

    loadDefaultServices(serviceLoader)

    when requires "tim":
        serviceLoader.services["tim"] = Service(
            name: "Tim",
            `type`: SingletonPackage,
            withArgs: true,
            args: @[
                SArg(k: "source", v: "./templates"),
                SArg(k: "output", v: "./storage/templates"),
                SArg(k: "indent", v: "4", kind: ArgTypeInt),
                SArg(k: "minified", v: "true", kind: ArgTypeBool)
            ]
        )

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
            result.add(newImport id )                       # import third-party services
        if service.expose:
            result.add(newExclude(id))

        if service.withArgs:
            var callWithArgs = nnkCall.newTree()
            callWithArgs.add(ident "init")
            callWithArgs.add(ident service.name)
            for arg in service.args:
                var argLit: NimNode
                case arg.kind
                of ArgTypeBool:
                    argLit = newLit(parseBool(arg.v))
                of ArgTypeInt:
                    argLit = newLit(parseInt(arg.v))
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

template init*(config: var StaticConfig) = 
    if not dirExists(baseCachePath):
        discard staticExec("mkdir " & baseCachePath)

    # Compile-time proc for parsing and validating YAML
    # config file `.env.yml` to `Config` object
    # Parse and validates YAML config file `.env.yml`
    # to `Config` object    when defined webapp:
        let publicDir = Config.app.assets.public
        result.add quote do:
            let publicDir = `publicDir`
    Config = ymlParser(configContents, StaticConfig)

    if Config.app.address.len == 0:
        Config.app.address = $getPrimaryIPAddr()

# macro writeAppConfig() =
#     result = newStmtList()
#     var appAddrNode: NimNode
#     if Config.app.address.len == 0:
#         appAddrNode = nnkPrefix.newTree(
#             ident "$",
#             nnkPar.newTree(
#                 newCall(ident "getPrimaryIPAddr")
#             )
#         )
#     else:
#         appAddrNode = newLit(Config.app.address)

#     result.add(
#         # when defined webapp
#         newWhenStmt(
#             (
#                 nnkCommand.newTree(
#                     ident "defined",
#                     ident "webapp"
#                 ),
#                 nnkStmtList.newTree(
#                     newLetStmt(
#                         ident "publicDir",
#                         newLit(Config.app.assets.public)
#                     ),
#                     newVarStmt(
#                         ident "sourceDir",
#                         newLit(Config.app.assets.source)
#                     ),

#                     newIfStmt(
#                         (
#                             nnkInfix.newTree(
#                                 ident "and",
#                                 nnkInfix.newTree(
#                                     ident "==",
#                                     newDotExpr(
#                                         ident "publicDir",
#                                         ident "len"
#                                     ),
#                                     newLit(0)
#                                 ),
#                                 nnkInfix.newTree(
#                                     ident "==",
#                                     newDotExpr(
#                                         ident "sourceDir",
#                                         ident "len"
#                                     ),
#                                     newLit(0)
#                                 )
#                             ),
#                             newExceptionStmt(
#                                 ident "ApplicationDefect",
#                                 newLit "Invalid project structure. Missing `public` and `source` directories"
#                             )
#                         )
#                     ),
#                     newAssignment(
#                         ident "sourceDir",
#                         newCall(
#                             ident "normalizedPath",
#                             nnkInfix.newTree(
#                                 ident "&",
#                                 nnkInfix.newTree(
#                                     ident "&",
#                                     newCall(ident "getAppDir"),
#                                     newLit("/")
#                                 ),
#                                 ident "sourceDir"
#                             )
#                         )
#                     ),
#                     newCall(
#                         newDotExpr(
#                             ident "Assets",
#                             ident "init"
#                         ),
#                         ident "sourceDir",
#                         ident "publicDir",
#                     ),
#                     newAssignment(
#                         newDotExpr(
#                             ident "App",
#                             ident "hasTemplates"
#                         ),
#                         ident "true"
#                     )
#                 )
#             ),
#             # else
#             newAssignment(
#                 newDotExpr(
#                     ident "App",
#                     ident "appType"
#                 ),
#                 ident "RESTful"
#             )
#         )
#     )

#     result.add(
#         newAssignment(
#             newDotExpr(ident "App", ident "domain"),
#             ident "AF_INET"
#         ),
#         newAssignment(
#             newDotExpr(ident "App", ident "address"),
#             appAddrNode
#         ),
#         newAssignment(
#             newDotExpr(ident "App", ident "port"),
#             newCall(
#                 ident "Port",
#                 newLit Config.app.port
#             )
#         ),
#         newAssignment(
#             newDotExpr(ident "App", ident "threads"),
#             newLit Config.app.threads
#         ),
#         newAssignment(
#             newDotExpr(ident "App", ident "recyclable"),
#             newLit(true)
#         ),
#         newAssignment(
#             newDotExpr(ident "App", ident "isInitialized"),
#             newLit(true)
#         ),
#     )