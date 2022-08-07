import std/[osproc, macros]
from std/os import walkDirRec, isHidden
from std/strutils import endsWith, strip, split

const ymlConfigSample* = """
app:
  port: 9933
  address: "127.0.0.1"
  name: "Supranim Application"
  key: ""
  threads: 1
  assets:
    source: "./assets"
    public: "assets"
  views: "views"

database:
  main:
    driver: "pgsql"
    port: 5432
    host: "localhost"
    prefix: "my_"
    name: "app_sample"
    user: "username"
    password: "postgres"
"""

proc cmd*(inputCmd: string, inputArgs: openarray[string]): any {.discardable.} =
    ## Short hand for executing shell commands via execProcess
    result = execProcess(inputCmd, args=inputArgs, options={poStdErrToStdOut, poUsePath})

proc cmdExec*(inputCmd: string): tuple[output: TaintedString, exitCode: int] =
    ## Execute a command
    execCmdEx(inputCmd)

proc finder*(findArgs: seq[string] = @[], path: string, ext = ""): seq[string] {.thread.} =
    ## TODO Support search for multiple extensions
    when defined windows:
        var byExtension = if ext.len == 0: false else: true
        for file in walkDirRec(path):
            if file.isHidden: continue
            if byExtension:
                if file.endsWith(ext):
                    result.add(file)
            else:
                result.add file
    else:
        var args: seq[string] = findArgs
        args.insert(path, 0)
        var files = cmd("find", args).strip()
        if files.len == 0: # "Unable to find any files at given location"
            result = @[]
        else:
            for file in files.split("\n"):
                if file.isHidden: continue
                result.add file

proc newImport*(id: string): NimNode =
    result = newNimNode(nnkImportStmt)
    result.add ident(id)

proc newInclude*(id: string): NimNode =
    result = newNimNode(nnkIncludeStmt)
    result.add ident(id)

proc newExclude*(id: string): NimNode =
    result = newNimNode(nnkExportStmt)
    result.add ident(id)

proc newWhenStmt*(whenBranch: tuple[cond, body: NimNode]): NimNode =
    ## Constructor for `when` statements.
    result = newNimNode(nnkWhenStmt)
    # if len(branches) < 1:
    #     error("When statement must have at least one branch")
    result.add(newTree(nnkElifBranch, whenBranch.cond, whenBranch.body))

proc newWhenStmt*(whenBranch: tuple[cond, body: NimNode], elseBranch: NimNode): NimNode =
    ## Constructor for `when` statements.
    result = newNimNode(nnkWhenStmt)
    # if len(branches) < 1:
    #     error("When statement must have at least one branch")
    result.add(newTree(nnkElifBranch, whenBranch.cond, whenBranch.body))
    result.add(newTree(nnkElse, elseBranch))

proc newExceptionStmt*(exception: NimNode, msg: NimNode): NimNode =
    expectKind(exception, nnkIdent)
    expectKind(msg, nnkStrLit)
    result = newNimNode(nnkRaiseStmt)
    result.add(
        newCall(
            ident "newException",
            ident exception.strVal,
            newLit msg.strVal
        )
    )
