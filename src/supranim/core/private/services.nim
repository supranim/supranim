import std/tables

type
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

    ServiceCenter* = object
        services*: Table[string, Service]

include ./runtime

template loadServiceCenter*() =
    var runtimeHandler = Runtime()
    var serviceCenter = ServiceCenter()
    serviceCenter.services["session"] = Service(
        name: "Session",
        `type`: SingletonDefault
    )

    serviceCenter.services["csrf"] = Service(
        name: "Csrf",
        `type`: SingletonDefault
    )

    serviceCenter.services["tim"] = Service(
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

    serviceCenter.services["emitter"] = Service(
        name: "Event",
        `type`: SingletonPackage,
        expose: true
    )

    for id, service in pairs(serviceCenter.services):
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

    writeFile(getProjectCachePath("runtime.nim"), runtimeHandler.getCode())
