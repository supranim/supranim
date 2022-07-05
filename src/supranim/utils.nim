import osproc
from std/os import walkDirRec, isHidden
from std/strutils import endsWith

proc cmd*(inputCmd: string, inputArgs: openarray[string]): any {.discardable.} =
    ## Short hand for executing shell commands via execProcess
    result = execProcess(inputCmd, args=inputArgs, options={poStdErrToStdOut, poUsePath})

proc cmdExec*(inputCmd: string): tuple[output: TaintedString, exitCode: int] =
    ## Execute a command
    execCmdEx(inputCmd)

proc finder*(findArgs: seq[string] = @[], path: string, ext = ""): seq[string] {.thread.} =
    ## TODO Support search for multiple extensions
    when defined windows:
        var byExtension = if ext.len != 0: false else: true
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