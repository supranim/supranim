#
#
#       Nim's Asynchronous Http Fileserver
#        (c) Copyright 2019 Henrique Dias
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#
import std/[asyncnet, asyncdispatch,
        asyncfile, os, strutils, httpcore,
        tables]

import ../http

from ../../application import storagePath

# https://developer.mozilla.org/en-US/docs/Web/HTTP/Basics_of_HTTP/MIME_types/Complete_list_of_MIME_types
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
  ".ogg":   "audio/ogg"
}.toTable

const maxFileSize = high(int)

proc sendFileChunksAsync(req: Request, filepath: string,
    headers: HttpHeaders = nil): Future[void] {.async.} =
  let filesize = cast[int](getFileSize(filepath))
  const chunkSize = 8*1024
  var msg = "HTTP/1.1 200\c\L"

  if headers != nil:
    for k, v in headers:
      msg.add("$1: $2\c\L" % [k,v])

  msg.add("Content-Length: ")
  msg.add $filesize
  msg.add "\c\L\c\L"
  var remainder = filesize
  var file = openAsync(filepath, fmRead)
  req.unsafeSend(msg)
  while remainder > 0:
    let data = await file.read(
        if remainder < chunkSize: remainder
        else: chunkSize
      )
    remainder -= data.len
    req.unsafeSend(data)
  file.close()

proc getMimetype*(ext: string): string =
  if mime_types.hasKey(ext):
    mime_types[ext]
  else:
    "application/octet-stream"

proc serveStaticFile*(req: Request, path: string, resHeaders: HttpHeaders, hasFoundResource: var bool) =
  let path = normalizedPath(path)
  if fileExists(storagePath / path):
    hasFoundResource = true
    let ext = path.splitFile.ext
    resHeaders["Content-Type"] = getMimetype(ext)
    waitFor req.sendFileChunksAsync(storagePath / path, resHeaders)

proc serveStaticFile*(req: Request, path: string, resHeaders: HttpHeaders) =
  let path = normalizedPath(path)
  if fileExists(storagePath / path):
    let ext = path.splitFile.ext
    resHeaders["Content-Type"] = getMimetype(ext)
    waitFor req.sendFileChunksAsync(storagePath / path, resHeaders)

proc serveStaticFileUnsafe*(req: Request, path: string, resHeaders: HttpHeaders) =
  ## Unsafe proc that reads file contents from path
  let path = normalizedPath(path)
  if fileExists(path):
    let ext = path.splitFile.ext
    resHeaders["Content-Type"] = getMimetype(ext)
    waitFor req.sendFileChunksAsync(path, resHeaders)