# Supranim is a simple MVC-style web framework for building
# fast web applications, REST API microservices and other cool things.
#
# (c) 2021 Supranim is released under MIT License
#          Made by Humans from OpenPeep
#          https://supranim.com | https://github.com/supranim

# Include-only file

from std/strutils import toLowerAscii, capitalizeAscii
from std/os import `/`

type
    StaticAppConfig = object
        app: tuple[
            port: int,
            address: string,
            name: string,
            key: string,
            threads: int,
            assets: tuple[source, public: string]
        ]
        # services: StaticAppServices

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

const SECURE_PROTOCOL = "https"
const UNSECURE_PROTOCOL = "http"
const NO = "no"
const YES = "yes"
const yamlEnvFile = ".env.yml"

var StaticConfig* {.compileTime.}: StaticAppConfig
var AppConfig {.compileTime.}: Document

let baseCachePath* {.compileTime.} = getProjectPath() /../ ".cache"

include ./runtime

proc getModule(file: string): string {.compileTime.} =
    result = "supranim" / "support" / toLowerAscii(file)

template loadDefaultServices(serviceLoader: var ServiceLoader, config: Document) =
    for serviceName in ["session", "csrf"]:
        let serviceSettings = config.get("supranim/" & serviceName)
        echo serviceSettings
        serviceLoader.services[serviceName] = Service(
            name: capitalizeAscii(serviceName),
            `type`: SingletonDefault
        )

template loadServiceCenter*(path: string) =
    var runtimeHandler = Runtime()
    var serviceLoader = ServiceLoader()
    let configServices = newDocument(AppConfig.get("services"))

    # loadDefaultServices(serviceLoader, configServices)

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
            result.add(
                nnkImportStmt.newTree(
                    ident getModule(id)
                )
            )
        else:
            result.add(
                nnkImportStmt.newTree(
                    ident id
                )
            )
            if service.expose:
                result.add(
                    nnkExportStmt.newTree(ident id)
                )
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
            result.add(
                newCall(
                    ident "init",
                    ident service.name,
                )
            )
        if service.`type` in {SingletonDefault, InstanceDefault}:
            runtimeHandler.add(id, true, true)
        else:
            runtimeHandler.add(id, true)

    writeFile(path / "runtime.nim", runtimeHandler.getCode())

when not defined inlineConfig:
    const confPath = getProjectPath() & "/../bin/"
    const ymlConfPath = confPath & ".env.yml"
    static:
        if not fileExists(ymlConfPath):
            writeFile(ymlConfPath, ymlConfigSample)
    const ymlConfigContents* = staticRead(ymlConfPath)

proc parseEnvFile(configContents: string): Document {.compileTime.} =
    # Private procedure for parsing and validating the
    # ``.env.yml`` configuration file.
    # 
    # The YML contents is parsed with Nyml library, for more details
    # related to Nyml limitations and YAML syntax supported by Nyml
    # check official repository: https://github.com/openpeep/nyml
    var yml = Nyml.init(contents = configContents)
    result = yml.toJson()
    StaticConfig = ymlParser(configContents, StaticAppConfig)

proc getAppDir(appDir: AppDirectory): string =
    result = getProjectPath() & "/" & $appDir

macro writeAppConfig() =
    result = newStmtList()
    var appAddrNode: NimNode
    if StaticConfig.app.address.len == 0:
        appAddrNode = nnkPrefix.newTree(
            ident "$",
            nnkPar.newTree(
                newCall(ident "getPrimaryIPAddr")
            )
        )
    else:
        appAddrNode = newLit(StaticConfig.app.address)

    result.add(
        # when defined webapp
        newWhenStmt(
            (
                nnkCommand.newTree(
                    ident "defined",
                    ident "webapp"
                ),
                nnkStmtList.newTree(
                    newLetStmt(
                        ident "publicDir",
                        newLit(StaticConfig.app.assets.public)
                    ),
                    newVarStmt(
                        ident "sourceDir",
                        newLit(StaticConfig.app.assets.source)
                    ),

                    newIfStmt(
                        (
                            nnkInfix.newTree(
                                ident "and",
                                nnkInfix.newTree(
                                    ident "==",
                                    newDotExpr(
                                        ident "publicDir",
                                        ident "len"
                                    ),
                                    newLit(0)
                                ),
                                nnkInfix.newTree(
                                    ident "==",
                                    newDotExpr(
                                        ident "sourceDir",
                                        ident "len"
                                    ),
                                    newLit(0)
                                )
                            ),
                            newExceptionStmt(
                                ident "ApplicationDefect",
                                newLit "Invalid project structure. Missing `public` and `source` directories"
                            )
                        )
                    ),
                    newAssignment(
                        ident "sourceDir",
                        newCall(
                            ident "normalizedPath",
                            nnkInfix.newTree(
                                ident "&",
                                nnkInfix.newTree(
                                    ident "&",
                                    newCall(ident "getAppDir"),
                                    newLit("/")
                                ),
                                ident "sourceDir"
                            )
                        )
                    ),
                    newCall(
                        newDotExpr(
                            ident "Assets",
                            ident "init"
                        ),
                        ident "sourceDir",
                        ident "publicDir",
                    ),
                    newAssignment(
                        newDotExpr(
                            ident "App",
                            ident "hasTemplates"
                        ),
                        ident "true"
                    )
                )
            ),
            # else
            newAssignment(
                newDotExpr(
                    ident "App",
                    ident "appType"
                ),
                ident "RESTful"
            )
        )
    )

    result.add(
        newAssignment(
            newDotExpr(ident "App", ident "domain"),
            ident "AF_INET"
        ),
        newAssignment(
            newDotExpr(ident "App", ident "address"),
            appAddrNode
        ),
        newAssignment(
            newDotExpr(ident "App", ident "port"),
            newCall(
                ident "Port",
                newLit StaticConfig.app.port
            )
        ),
        newAssignment(
            newDotExpr(ident "App", ident "threads"),
            newLit StaticConfig.app.threads
        ),
        newAssignment(
            newDotExpr(ident "App", ident "recyclable"),
            newLit(true)
        ),
        newAssignment(
            newDotExpr(ident "App", ident "isInitialized"),
            newLit(true)
        ),
    )