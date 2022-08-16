# Supranim is a simple MVC-style web framework for building
# fast web applications, REST API microservices and other cool things.
#
# (c) 2021 Supranim is released under MIT License
#          George Lemon | Made by Humans from OpenPeep
#          https://supranim.com   |    https://github.com/supranim

from std/os import isHidden
from std/strutils import strip, split, join, replace

when defined windows:
    from std/os import walkDirRec
else:
    import std/osproc

type 
    SearchType* = enum
        SearchFiles, SearchDirectories

when not defined windows:
    proc cmd*(bin: string, inputArgs: openarray[string]): any {.discardable.} =
        ## Short hand for executing shell commands via execProcess
        execProcess(bin, args=inputArgs, options={poStdErrToStdOut, poUsePath})

    proc staticCmd*(bin: string, inputArgs: openarray[string]): any {.discardable, compileTime.} =
        staticExec(bin & " " & join(inputArgs, " "))

    proc finder*(searchType: SearchType, path: string, ext = ""): seq[string] =
        var files = cmd("find", [path, "-type", "f", "-print"]).strip()
        if files.len == 0: # "Unable to find any files at given location"
            result = @[]
        else:
            for file in files.split("\n"):
                if file.isHidden: continue
                result.add file
    
    proc staticFinder*(searchType: SearchType, path: string, ext = "", showRelativePath = false): seq[string] {.compileTime.} =
        var files = staticCmd("find", [path, "-type", "f", "-print"]).strip()
        if files.len == 0: # "Unable to find any files at given location"
            result = @[]
        else:
            for file in files.split("\n"):
                if file.isHidden: continue
                if showRelativePath:
                    result.add file.replace(path, "")
                else:
                    result.add file
# else:
#     proc finder*(searchType: SearchType, path: string, ext = ""): Future[seq[string]] {.async.} =
#         var retFuture = newFuture[seq[string]]("finder")
#         var byExtension = if ext.len == 0: false else: true
#         for file in walkDirRec(path):
#             if file.isHidden: continue
#             if byExtension:
#                 if file.endsWith(ext):
#                     result.add(file)
#             else:
#                 result.add file