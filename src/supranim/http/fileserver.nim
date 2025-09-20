#
# Supranim is a full-featured web framework for building
# web apps & microservices in Nim.
# 
#   (c) 2025 MIT License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#
import std/[os, strutils, httpcore, tables]

import ./webserver
from ../application import storagePath

# https://developer.mozilla.org/en-US/docs/Web/HTTP/Basics_of_HTTP/MIME_types/Complete_list_of_MIME_types
# todo use pkg/mimedb
const mime_types = {
  ".bz":     "application/x-bzip",
  ".bz2":    "application/x-bzip2",
  ".css":    "text/css",
  ".doc":    "application/msword",
  ".docx":   "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  ".eot":    "application/vnd.ms-fontobject",
  ".gif":    "image/gif",
  ".gz":     "application/gzip",
  ".htm":    "text/html",
  ".html":   "text/html",
  ".ico":    "image/vnd.microsoft.icon",
  ".jpeg":   "image/jpeg",
  ".jpg":    "image/jpeg",
  ".js":     "text/javascript",
  ".json":   "application/json",
  ".odp":    "application/vnd.oasis.opendocument.presentation",
  ".ods":    "application/vnd.oasis.opendocument.spreadsheet",
  ".odt":    "application/vnd.oasis.opendocument.text",
  ".otf":    "font/otf",
  ".png":    "image/png",
  ".pdf":    "application/pdf",
  ".ppt":    "application/vnd.ms-powerpoint",
  ".pptx":   "application/vnd.openxmlformats-officedocument.presentationml.presentation",
  ".rar":    "application/x-rar-compressed",
  ".rtf":    "application/rtf",
  ".svg":    "image/svg+xml",
  ".tar":    "application/x-tar",
  ".tgz":    "application/tar+gzip",
  ".ttf":    "font/ttf",
  ".txt":    "text/plain",
  ".woff":   "font/woff",
  ".woff2":  "font/woff2",
  ".xhtml":  "application/xhtml+xml",
  ".xls":    "application/vnd.ms-excel",
  ".xlsx":   "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  ".xul":    "application/vnd.mozilla.xul+xml",
  ".xml":    "text/xml",
  ".webapp": "application/x-web-app-manifest+json",
  ".zip":    "application/zip",
  ".opus":   "audio/ogg",
  ".ogg":   "audio/ogg",
  ".webp":   "image/webp"
}.toTable

const maxFileSize = high(int)

proc getMimetype*(ext: string): string =
  if mime_types.hasKey(ext): mime_types[ext]
  else: "application/octet-stream"

proc sendAssets*(req: var Request, path: string, 
        headers: HttpHeaders, hasFoundResource: var bool) =
  ## Serves static assets from /assets path
  let path = normalizedPath(path)
  if fileExists(storagePath / path):
    headers.add("Content-Type", getMimetype(path.splitFile.ext))
    req.sendFile(storagePath / path, headers)
    hasFoundResource = true

proc sendAssets*(req: var Request, basePath, path: string,
        headers: HttpHeaders): bool =
  ## Serves static assets from /assets path
  let reqpath = normalizedPath(path)
  if fileExists(basePath / reqpath):
    let ext = reqpath.splitFile.ext
    if headers.hasKey("Content-Type"):
      # if content type already set, will override it
      # to avoid issues with wrong mime types
      headers["Content-Type"] = getMimetype(ext)
    else:
      headers.add("Content-Type", getMimetype(ext))
    if ext in [".woff", ".woff2", ".ttf", ".otf", ".eot"]:
      headers["Access-Control-Allow-Origin"] = "*"
    req.sendFile(basePath / reqpath, headers)
    result = true