# Supranim is a simple MVC-style web framework for building
# fast web applications, REST API microservices and other cool things.
# 
# Suppliers are the central place of all Supranim applications.
# Supplier Manager is part of Supranim and Sup CLI and gives you
#
# (c) 2021 Supranim is released under MIT License
#          George Lemon | Made by Humans from OpenPeep
#          https://supranim.com   |    https://github.com/supranim

import pkginfo
import std/[macros, tables]
from std/os import normalizedPath, fileExists
from std/strutils import toLowerAscii

type
    SysPermissions = object

    AppPermissions = object

    BlockType* = enum
        Import, Include, SysImport, SysInclude

    AppDirectory* = enum
        ## Known Supranim application paths
        None
        AppConfigs = "configs"
        AppControllers = "controller"
        AppDatabases = "database"
        AppModels = "database/models"
        AppMigrations = "database/migrations"
        AppSeeds = "database/seeds"
        AppEvents = "events"
        AppListeners = "events/listeners"
        AppSchedules = "events/schedules"
        AppI18n = "i18n"
        AppMiddlewares = "middlewares"

    Supplier* = object of RootObj
        id: string
            ## Identifier of the current service supplier
        permissions: tuple[system: SysPermissions, app: AppPermissions]
            ## Permissions required by the current service supplier

var Snippets* {.compileTime.}: TableRef[string, seq[string]]

proc initSupplier*[S](supplier: typedesc[S]): ref S =
    var supplierInstance = new supplier
    supplierInstance.id = toLowerAscii($(supplier))

macro newSupplier*(supplierName: static string) =
    result = newStmtList()
    result.add(
        nnkTypeSection.newTree(
            nnkTypeDef.newTree(
                nnkPostfix.newTree(
                    ident "*",
                    ident supplierName
                ),
                newEmptyNode(),
                nnkObjectTy.newTree(
                    newEmptyNode(),
                    nnkOfInherit.newTree(ident "Supplier"),
                    newEmptyNode()
                )
            )
        )
    )

    if Snippets == nil:
        Snippets = newTable[string, seq[string]]()

    if not Snippets.hasKey supplierName:
        Snippets[supplierName] = newSeq[string]()

    result.add(
        nnkConstSection.newTree(
            nnkConstDef.newTree(
                newIdentNode("supplierIdent"),
                newEmptyNode(),
                newLit(supplierName)
            )
        )
    )

proc `@`*(paths: (AppDirectory, string)): (AppDirectory, string) {.compileTime.} =
    let path = normalizedPath(getProjectPath() & "/" & $paths[0] & "/" & paths[1])
    if not path.fileExists(): (paths[0], path)
    else: (None, "")

macro use*(pkgName: static string, paths: (AppDirectory, string), code) =
    ## Extend Supranim functionality by using the API of
    ## the currently installed packages.
    Snippets["Grant"].add code.repr
