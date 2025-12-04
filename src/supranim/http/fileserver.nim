#
# Supranim - A high-performance MVC web framework for Nim,
# designed to simplify web application and REST API development.
# 
#   (c) 2025 MIT License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#

import std/[os, strutils, httpcore, tables, options]
import pkg/mimedb

import ./webserver
from ../application import storagePath

const maxFileSize = high(int)

proc sendAssets*(req: var Request, path: string, 
        headers: HttpHeaders, hasFoundResource: var bool) =
  ## Serves static assets from /assets path
  let path = normalizedPath(path)
  if fileExists(storagePath / path):
    headers.add("Content-Type", mimedb.getMimeType(path.splitFile.ext[1..^1]).get("application/octet-stream"))
    req.sendFile(storagePath / path, headers)
    hasFoundResource = true

proc sendAssets*(req: var Request, basePath, path: string,
        headers: HttpHeaders): bool =
  ## Serves static assets from /assets path
  let reqpath = normalizedPath(path)
  if fileExists(basePath / reqpath):
    let ext = reqpath.splitFile.ext
    let typ = mimedb.getMimeType(ext[1..^1]).get("application/octet-stream")
    if headers.hasKey("Content-Type"):
      # if content type already set, will override it
      # to avoid issues with wrong mime types
      headers["Content-Type"] = typ
    else:
      headers.add("Content-Type", typ)
    if ext in [".woff", ".woff2", ".ttf", ".otf", ".eot"]:
      headers["Access-Control-Allow-Origin"] = "*"
    req.sendFile(basePath / reqpath, headers)
    result = true