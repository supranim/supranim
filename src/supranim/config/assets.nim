# Supranim is a simple Hyper Server and Web Framework developed
# for building safe & fast in-house applications.
#
# (c) 2021 Supranim is released under MIT License
#          by George Lemon <georgelemon@protonmail.com>
#          
#          Website https://supranim.com
#          Github Repository: https://github.com/supranim

import std/tables
from std/os import fileExists, getCurrentDir, splitPath
from std/strutils import strip, split

import ../utils

export tables

type
    Assets* = ref object
        source: string
        public: string
        files: Table[string, File]

    File = object
        alias, path: string

    AssetsError* = CatchableError

proc finder*(findArgs: seq[string] = @[], path=""): seq[string] {.thread.} =
    ## Simple file system procedure that discovers static files in a specific directory
    var args: seq[string] = findArgs
    args.insert(path, 0)
    var files = cmd("find", args).strip()
    if files.len == 0:
        raise newException(AssetsError, "Unable to find any static files")
    else:
        result = files.split("\n")

proc getPublicPath*[A: Assets](assets: A): string = 
    ## Retrieve the public path for assets
    result = "/" & assets.public

proc getSourcePath*[A: Assets](assets: A): string =
    ## Retrieve the source path for assets
    result = assets.source

proc hasFile*[T: Assets](assets: T, alias: string): bool =
    ## Determine if requested file exists
    if assets.files.hasKey(alias):
        result = fileExists(assets.files[alias].path)

proc addFile*[T: Assets](assets: var T, alias, path: string) =
    ## Add a new File object to Assets collection
    if not assets.hasFile(alias):
        assets.files[alias] = File(alias: alias, path: path)

proc init*[T: typedesc[Assets]](newAssets: T, source, public: string): Assets =
    ## Initialize a new Assets object collection
    var assets = newAssets(source: source, public: public)
    let files = finder(findArgs = @["-type", "f", "-print"], path = source)
    if files.len != 0:
        for file in files:
            let f = splitPath(file)
            assets.addFile("/" & public & "/" & f.tail, file)
    result = assets

proc getFile*[T: Assets](assets: T, alias: string): string =
    ## Retrieve the contents of requested file
    result = readFile(assets.files[alias].path)
