#
# Supranim is a high-performance web framework for building
# web applications and microservices in Nim
#
#   (c) 2026 LGPL-v3-or-later License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#

## Static file serving helpers.
## Serves embedded assets via `service/assets` and disk assets via `mimedb`
## with traversal protection, ETags, conditional requests, byte ranges
## and download support.

import std/[os, strutils, httpcore, options, times]
import pkg/mimedb

import ../network/webserver
import ../service/assets

from ../core/application import storagePath

proc isTraversalPath*(path: string): bool =
  ## True when `path` escapes its base directory (any `..` segment).
  ## Check the normalized path *before* joining it to a base directory:
  ## traversal attempts are treated as not-found (no information leak).
  for part in normalizedPath(path).split('/'):
    if part == "..":
      return true
  false

proc mimeFor*(ext: string): string =
  ## Maps a file extension (with or without leading dot, possibly empty)
  ## to a MIME type. Never raises, even for missing/odd extensions.
  let e = ext.strip(chars = {'.'})
  if e.len == 0:
    return "application/octet-stream"
  mimedb.getMimeType(e).get("application/octet-stream")

proc fileETag*(size: int64, mtime: Time): string =
  ## Weak ETag from file size + mtime (`W/"<size>-<mtime>"`, hex).
  ## Stable for unchanged files, changes on any write. Pure, unit-testable.
  "W/\"" & size.toHex & "-" & mtime.toUnix.toHex & "\""

proc httpDate*(t: Time): string =
  ## Formats `t` as an HTTP date for `Date` / `Last-Modified`.
  t.utc.format("ddd, dd MMM yyyy HH:mm:ss 'GMT'")

proc setStaticCacheHeaders*(headers: HttpHeaders, etag,
    lastModified: string) =
  ## `ETag` + `Last-Modified` + `Cache-Control` + `Accept-Ranges`.
  headers.add("ETag", etag)
  headers.add("Last-Modified", lastModified)
  headers.add("Cache-Control", "public, max-age=86400")
  headers.add("Accept-Ranges", "bytes")

proc notModified*(req: var Request, etag: string): bool =
  ## True when the request's `If-None-Match` matches `etag` (or is `*`).
  ## Pure header check — no I/O, unit-testable.
  let h = req.getHeader("if-none-match")
  if h.isNone:
    return false
  let v = h.get().strip()
  v == "*" or v == etag

proc sendEmbeddedAsset*(req: var Request, path: string, 
                headers: HttpHeaders, foundRes: var bool) =
  ## Serves static assets from embedded resources
  let path = normalizedPath(path)
  let splitPath = path.splitFile
  if splitPath.ext.len > 0:
    headers.add("Content-Type", mimeFor(splitPath.ext))
    try:
      if staticAssets().directory("assets").hasFile(path):
        let body = staticAssets().directory("assets").getFile(path)
        let etag = "W/\"" & body.len.toHex & "\""
        headers.add("ETag", etag)
        headers.add("Cache-Control", "public, max-age=86400")
        if req.notModified(etag):
          req.send(Http304, "", headers)
        else:
          req.send(200, body, headers)
        foundRes = true
      elif staticAssets().hasAsset(path):
        req.sendFile(staticAssets().get(path), headers)
        foundRes = true
    except StaticAssetsError:
      foundRes = false

proc sendAssetRangeOrFile(req: var Request, fpath: string,
    headers: HttpHeaders) =
  ## Shared disk-file sender: ETag + conditional (`304`), byte-range
  ## (`206` via `streamFile`, `416` when unsatisfiable), else `sendFile`.
  ## Callers guarantee `fpath` exists and is traversal-free.
  let info = getFileInfo(fpath)
  let etag = fileETag(info.size, info.lastWriteTime)
  setStaticCacheHeaders(headers, etag, httpDate(info.lastWriteTime))
  if req.notModified(etag):
    req.send(Http304, "", headers)
    return
  let rangeHdr = req.getHeader("range").get("")
  if rangeHdr.len > 0:
    if parseRangeHeader(rangeHdr, info.size.int).isSome:
      req.streamFile(fpath, headers)
    else:
      headers.add("Content-Range", "bytes */" & $info.size)
      req.send(Http416, "", headers)
  else:
    req.sendFile(fpath, headers)

proc sendAssets*(req: var Request, path: string, 
        headers: HttpHeaders, foundRes: var bool) =
  ## Serves static assets from /assets path
  let path = normalizedPath(path)
  if not isTraversalPath(path) and fileExists(storagePath / path):
    headers.add("Content-Type", mimeFor(path.splitFile.ext))
    req.sendAssetRangeOrFile(storagePath / path, headers)
    foundRes = true

proc sendAssets*(req: var Request, basePath, path: string,
        headers: HttpHeaders): bool =
  ## Serves static assets from /assets path
  let reqPath = normalizedPath(path)
  if isTraversalPath(reqPath):
    return false
  if fileExists(basePath / reqPath):
    let ext = reqPath.splitFile.ext
    let typ = mimeFor(ext)
    if headers.hasKey("Content-Type"):
      headers["Content-Type"] = typ
    else:
      headers.add("Content-Type", typ)
    if ext in [".woff", ".woff2", ".ttf", ".otf", ".eot"]:
      headers["Access-Control-Allow-Origin"] = "*"
    req.sendAssetRangeOrFile(basePath / reqPath, headers)
    result = true

proc sendAssetFile*(req: var Request, filepath: string, headers: HttpHeaders) =
  ## Serves a file from the filesystem with the appropriate content type
  if isTraversalPath(filepath) or not fileExists(filepath):
    req.send(404, "Asset not found")
  else:
    let ext = filepath.splitFile.ext
    let typ = mimeFor(ext)
    if headers.hasKey("Content-Type"):
      headers["Content-Type"] = typ
    else:
      headers.add("Content-Type", typ)
    req.sendAssetRangeOrFile(filepath, headers)

proc sendDownloadable*(req: var Request, filepath: string,
              headers: HttpHeaders) =
  ## Serves a file as a downloadable attachment, prompting the user to save it.
  if isTraversalPath(filepath) or not fileExists(filepath):
    req.send(404, "Asset not found")
    return
  let splitPath = filepath.splitFile
  let ext = splitPath.ext
  let name = splitPath.name
  let typ = mimeFor(ext)
  headers["Content-Disposition"] = "attachment; filename=\"" & name & ext & "\""
  if headers.hasKey("Content-Type"):
    headers["Content-Type"] = typ
  else:
    headers.add("Content-Type", typ)
  let info = getFileInfo(filepath)
  let etag = fileETag(info.size, info.lastWriteTime)
  headers.add("ETag", etag)
  headers.add("Cache-Control", "private, max-age=86400")
  headers.add("Accept-Ranges", "bytes")
  if req.notModified(etag):
    req.send(Http304, "", headers)
    return
  req.sendFile(filepath, headers)
