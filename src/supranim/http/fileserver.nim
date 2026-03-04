#
# Supranim is a full-featured web framework for building
# web apps & microservices in Nim.
# 
#   (c) 2025 MIT License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#
import std/[os, strutils, httpcore, tables, options]
import pkg/mimedb

import ../network/http/webserver
import ../service/assets

from ../core/application import storagePath

proc sendEmbeddedAsset*(req: var Request, path: string, 
        headers: HttpHeaders, hasFoundResource: var bool) =
  ## Serves static assets from embedded resources
  let path = normalizedPath(path)
  headers.add("Content-Type",
    mimedb.getMimeType(path.splitFile.ext[1..^1]).get("application/octet-stream"))
  try:
    if staticAssets().hasAssetString(path):
      req.send(200, staticAssets().getAssetString(path), headers)
      hasFoundResource = true
    elif staticAssets().hasAsset(path):
      req.sendFile(staticAssets().get(path), headers)
      hasFoundResource = true
  except StaticAssetsError:
    hasFoundResource = false

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
  let reqPath = normalizedPath(path)
  if fileExists(basePath / reqPath):
    let ext = reqPath.splitFile.ext
    let typ = mimedb.getMimeType(ext[1..^1]).get("application/octet-stream")
    if headers.hasKey("Content-Type"):
      # if content type already set, will override it
      # to avoid issues with wrong mime types
      headers["Content-Type"] = typ
    else:
      headers.add("Content-Type", typ)
    if ext in [".woff", ".woff2", ".ttf", ".otf", ".eot"]:
      headers["Access-Control-Allow-Origin"] = "*"
    req.sendFile(basePath / reqPath, headers)
    result = true