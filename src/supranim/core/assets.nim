# Supranim is a simple MVC web framework
# for building web apps & microservices in Nim.
#
# (c) 2024 MIT License | Made by Humans from OpenPeeps
# https://supranim.com | https://github.com/supranim

import pkg/[filetype, find]
import std/[tables, asyncdispatch]

from std/httpcore import HttpCode
from std/strutils import strip, split, contains, replace
from std/os import FilePermission, fileExists, splitFile, 
          getFilePermissions, normalizedPath, `/`

# import std/fileExists

type
  File = ref object
    alias, path: string
    fileType: string

  AssetsHandler = ref object
    source: string
    public: string
    files: TableRef[string, File]

when compileOption("threads"):
  var Assets* {.threadvar.}: AssetsHandler
else:
  var Assets* = AssetsHandler()

proc exists*(assets: AssetsHandler): bool =
  if Assets.files != nil:
    result = Assets.files.len != 0

proc getPublicPath*(assets: AssetsHandler): string = 
  ## Retrieve the public path for assets
  result = assets.public

proc getSourcePath*(assets: AssetsHandler): string =
  ## Retrieve the source path for assets
  result = assets.source

proc hasFile*(assets: AssetsHandler, fileName: string): Future[HttpCode] {.async.} =
  ## Determine if requested file exists
  if assets.files.hasKey(fileName):
    result = HttpCode(200)
    if fileExists(assets.files[fileName].path):
      var fp = getFilePermissions(assets.files[fileName].path)
      if not fp.contains(fpOthersRead):
        return HttpCode(403)
  else:
    result = HttpCode(404)

proc addFile*(assets: var AssetsHandler, fileName, filePath: string) =
  ## Add a new File object to Assets collection
  if not assets.files.hasKey(fileName):
    let normalizedFilePath = normalizedPath(filePath)
    assets.files[fileName] = File(
      alias: fileName,
      path: normalizedFilePath,
      fileType: matchFile(normalizedFilePath).mime.value
    )

proc init*(assets: var AssetsHandler, source, public: string) =
  ## Initialize a new Assets object collection
  assets.files = newTable[string, File]()
  assets.source = source
  assets.public =
    if public[0] == '/':
      public
    else:
      "/" & public
  if assets.public[^1] != '/':
    add assets.public, "/"
  let files = finder(findArgs = @["-type", "f", "-print"], path = source)
  if files.len != 0:
    for file in files:
      let f = splitFile(file)
      if f.ext in [".sass", ".scss"]:
        continue # add this to supranim.config.yml
      var head = f.dir.replace(assets.source, "")
      when defined windows:
        head = head.replace("\\", "/")
      assets.addFile(normalizedPath(assets.public & head / f.name & f.ext), file)

proc getFile*(assets: AssetsHandler, fileName: string): tuple[src, fileType: string] =
  ## Retrieve the contents of requested file
  result = (readFile(assets.files[fileName].path), assets.files[fileName].fileType)
