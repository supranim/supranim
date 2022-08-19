import pkginfo, nyml
import std/[macros, tables, strutils, cpuinfo, compilesettings]

import ./config
import ../utils
import ../finder

when requires "emitter":
    import emitter
when defined webapp:
    import ./assets

from std/nativesockets import Domain
from std/net import `$`, Port
from std/logging import Logger
from std/os import getCurrentDir, putEnv, getEnv, fileExists,
                    getAppDir, normalizedPath, walkDirRec, copyFile,
                    dirExists, `/../`, `/`
export strutils.indent
export config.baseCachePath

type
    AppDirectory* = enum
        ## Known Supranim application paths
        # Config              = "configs"
        Controller          = "controller"
        Database            = "database"
        DatabaseMigrations  = "database/migrations"
        DatabaseModels      = "database/models"
        DatabaseSeeds       = "database/seeds"
        EventListeners      = "events/listeners"
        EventSchedules      = "events/schedules"
        I18n                = "i18n"
        Middlewares         = "middlewares"

    Application* = object

    AppDefect* = object of CatchableError

when compileOption "threads":
    var App* {.threadvar.}: Application
else:
    var App* = Application()

proc getAppDir(appDir: AppDirectory): string =
    result = getProjectPath() & "/" & $appDir

macro init*(app: var Application, autoIncludeRoutes: static bool = true) =
    ## Supranim application initializer.
    result = newStmtList()
    Config.init()
    when defined webapp:
        when not defined release:
            let publicDirPath = Config.getPublicPathAssets()
            let sourceDirPath = Config.getSourcePathAssets()
            result.add quote do:
                let publicDir = `publicDirPath`
                var sourceDir = `sourceDirPath`
                if publicDir.len == 0 or sourceDir.len == 0:
                    raise newException(AppDefect,
                        "Invalid project structure. Missing `public` or `source` directories")
                Assets.init(sourceDir, publicDir)
    loadServiceCenter()

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