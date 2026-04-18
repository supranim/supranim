#
# Supranim is a high-performance web framework for building
# web applications and microservices in Nim
# 
#   (c) 2026 LGPL-v3-or-later License | Made by Humans from OpenPeeps
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
  let splitPath = path.splitFile
  if path.splitFile.ext.len > 0:
    let mimeType = mimedb.getMimeType(splitPath.ext[1..^1]).get("application/octet-stream")
    headers.add("Content-Type", mimeType)
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
      headers["Content-Type"] = typ
    else:
      headers.add("Content-Type", typ)
    if ext in [".woff", ".woff2", ".ttf", ".otf", ".eot"]:
      headers["Access-Control-Allow-Origin"] = "*"
    req.sendFile(basePath / reqPath, headers)
    result = true

proc sendDownloadable*(req: var Request, filepath: string,
              headers: HttpHeaders) =
  ## Serves a file as a downloadable attachment, prompting the user to save it.
  if likely(fileExists(filepath)):
    let splitPath = filepath.splitFile
    let ext = splitPath.ext
    let name = splitPath.name
    let typ = mimedb.getMimeType(ext[1..^1]).get("application/octet-stream")
    headers["Content-Disposition"] = "attachment; filename=\"" & name & ext & "\""
    if headers.hasKey("Content-Type"):
      headers["Content-Type"] = typ
    else:
      headers.add("Content-Type", typ)
    req.sendFile(filepath, headers)