# Supranim is a simple Hyper Server and Web Framework developed
# for building safe & fast in-house applications.
#
# (c) 2021 Supranim is released under MIT License
#          by George Lemon <georgelemon@protonmail.com>
#          
#          Website https://supranim.com
#          Github Repository: https://github.com/supranim

import filetype
import std/[tables, asyncdispatch]
import ../utils

from std/httpcore import HttpCode
from std/strutils import strip, split, contains, replace
from std/os import FilePermission, fileExists, splitPath, 
                  getFilePermissions, normalizedPath, `/`

type
    File = object
        alias, path: string
        fileType: FileType

    AssetsHandler = ref object
        source: string
        public: string
        files: Table[string, File]

    AssetsError* = CatchableError

# when compileOption("threads"):
#     var Assets* {.threadvar.}: AssetsHandler
# else:
var Assets* = AssetsHandler()

proc exists*[A: AssetsHandler](assets: A): bool =
    result = Assets.files.len != 0

proc getPublicPath*[A: AssetsHandler](assets: A): string = 
    ## Retrieve the public path for assets
    result = "/" & assets.public

proc getSourcePath*[A: AssetsHandler](assets: A): string =
    ## Retrieve the source path for assets
    result = assets.source

proc hasFile*[T: AssetsHandler](assets: T, filePath: string): Future[HttpCode] {.async.} =
    ## Determine if requested file exists
    if assets.files.hasKey(filePath):
        result = HttpCode(200)
        if fileExists(assets.files[filePath].path):
            var fp = getFilePermissions(assets.files[filePath].path)
            if not fp.contains(fpOthersRead):
                return HttpCode(403)
    else:
        result = HttpCode(404)

proc addFile*[T: AssetsHandler](assets: var T, fn, filePath: string) =
    ## Add a new File object to Assets collection
    if not assets.files.hasKey(fn):
        let normalizedFilePath = normalizedPath(filePath)
        assets.files[fn] = File(alias: fn, path: normalizedFilePath, fileType: matchFile(normalizedFilePath))

proc init*[T: AssetsHandler](assets: var T, source, public: string) =
    ## Initialize a new Assets object collection
    assets.source = source
    assets.public = public
    let files = finder(findArgs = @["-type", "f", "-print"], path = source)
    if files.len != 0:
        for file in files:
            let f = splitPath(file)
            var head = f.head.replace(assets.source, "")
            when defined windows:
                head = head.replace("\\", "/")
            assets.addFile("/" & public & head & "/" & f.tail, file)

proc getFile*[T: AssetsHandler](assets: T, fileName: string): tuple[src, fileType: string] =
    ## Retrieve the contents of requested file
    result = (readFile(assets.files[fileName].path), assets.files[fileName].fileType.mime.value)
