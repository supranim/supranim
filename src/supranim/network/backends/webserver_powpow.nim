#
# Supranim is a high-performance web framework for building
# web applications and microservices in Nim
# 
#   (c) 2026 LGPL-v3-or-later License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#

import std/[os, posix, tables, httpcore, options,
           uri, strutils, strscans, sequtils, cpuinfo]

import pkg/threading/rwlock
import pkg/powpow as pw
import supranim/support/http
from std/net import Port, `$`

type
  WebServer* = ref object
    port*: Port
    enableMultiThreading*: bool
    powServer: pw.HttpServer
    powMultiServer: pw.MultiThreadHttpServer

  OnRequestLowLevel* = proc(req: pointer, arg: pointer) {.cdecl.}
  StartupCallback* = proc() {.gcsafe.}

  Request* = object
    raw*: pointer
    httpMethod*: HttpMethod
    clientIp: string
    path*: string
    uri*: Uri
    uriQuery*: TableRef[string, string]
    headers*: Option[HttpHeaders]
    body*: Option[string]
    routeParams*: Table[string, string]
    responseSent*: bool
    powReq: pw.HttpRequest
    powRes: pw.HttpResponse
    headersFetched: bool
    headersCache: HttpHeaders

when defined supranimUseGlobalOnRequest:
  type
    OnRequest* = proc(req: var Request) {.gcsafe.}
else:
  type
    OnRequest* = proc(req: var Request) {.nimcall, gcsafe.}

type
  BodyStream* = object
    bodyBytes: seq[byte]
    readOffset: int

proc normalizeCallbackPath(path: string): string {.inline.} =
  let p = if path.len == 0: "/" else: path
  normalizePath(p)

proc newWebServer*(port: Port = Port(8080)): WebServer =
  new(result)
  result.port = port
  result.enableMultiThreading = false

proc newWebServer*(port: Port = Port(8080), enableMultiThreading: bool): WebServer =
  new(result)
  result.port = port
  result.enableMultiThreading = enableMultiThreading

proc start*(server: var WebServer) =
  var dummy = pw.newHttpServer()
  dummy.start(nil, server.port)

proc start*(server: var WebServer, onRequest: OnRequest,
              startupCallback: StartupCallback = nil) =
  server.powServer = pw.newHttpServer()
  if startupCallback != nil:
    startupCallback()
  server.powServer.handler =
    proc(req: pw.HttpRequest, res: pw.HttpResponse) {.gcsafe.} =
      var uriStr = req.getUrl()
      var parsedUri = parseUri(uriStr)
      var sReq = Request(
        raw: cast[pointer](req),
        httpMethod: req.getMethod(),
        path: req.getPath(),
        uri: parsedUri,
        routeParams: initTable[string, string](),
        responseSent: false,
        powReq: req,
        powRes: res,
        clientIp: req.getClientIp(),
        headersFetched: false,
        headersCache: newHttpHeaders(),
      )
      if parsedUri.query.len > 0:
        var qTable = newTable[string, string]()
        for (k, v) in decodeQuery(parsedUri.query):
          qTable[k] = v
        sReq.uriQuery = qTable
      onRequest(sReq)
      if not sReq.responseSent:
        res.status(Http200).send("")
  server.powServer.listen("0.0.0.0", server.port.int)
  server.powServer.getLoop().run()
  server.powServer.close()
  server.powServer.getLoop().close()

proc start*(server: var WebServer, onRequest: OnRequest,
              startupCallback: StartupCallback,
              threads: int) =
  when not compileOption("threads"):
    {.error: "Multi-threaded Supranim requires threads support. Use `--threads:on`".}
  let nThreads = if threads > 0: threads else: countProcessors()
  server.powMultiServer = pw.newMultiThreadHttpServer(nThreads)
  if startupCallback != nil:
    startupCallback()
  server.powMultiServer.start(
    proc(req: pw.HttpRequest, res: pw.HttpResponse) {.gcsafe.} =
      var uriStr = req.getUrl()
      var parsedUri = parseUri(uriStr)
      var sReq = Request(
        raw: cast[pointer](req),
        httpMethod: req.getMethod(),
        path: req.getPath(),
        uri: parsedUri,
        routeParams: initTable[string, string](),
        responseSent: false,
        powReq: req,
        powRes: res,
        clientIp: req.getClientIp(),
        headersFetched: false,
        headersCache: newHttpHeaders(),
      )
      if parsedUri.query.len > 0:
        var qTable = newTable[string, string]()
        for (k, v) in decodeQuery(parsedUri.query):
          qTable[k] = v
        sReq.uriQuery = qTable
      onRequest(sReq)
      if not sReq.responseSent:
        res.status(Http200).send(""),
    "0.0.0.0", server.port.int)

proc send*(req: var Request, code: int, body: string, httpHeaders: HttpHeaders = nil) =
  if req.responseSent: return
  req.responseSent = true
  if httpHeaders != nil:
    for k, v in httpHeaders:
      req.powRes.header(k, v)
  req.powRes.status(HttpCode(code)).send(body)

proc send*(req: var Request, code: int, httpHeaders: HttpHeaders = nil) =
  send(req, code, "", httpHeaders)

proc send*(req: var Request, code: HttpCode, body: string, httpHeaders: HttpHeaders = nil) =
  req.send(code.int, body, httpHeaders)

proc startChunk*(req: Request) = discard
proc startPartialChunk*(req: Request) = discard
proc endChunk*(req: Request) = discard

template withChunks*(reqInstance: Request, httpHeaders: HttpHeaders, body) {.inject.} =
  body

proc sendChunk*(req: Request, data: string) =
  req.powRes.status(Http200).send(data)

proc getIp*(req: var Request): string = req.clientIp

proc getBody*(req: var Request): Option[string] =
  if req.body.isSome:
    return req.body
  let b = req.powReq.getBodyString()
  req.body = some(b)
  return req.body

proc dropRequest*(req: var Request) =
  req.raw = nil
  req.responseSent = true

proc getOutputHeaders*(req: Request): string = ""

proc getHeaders*(req: var Request): Option[HttpHeaders] =
  if not req.headersFetched:
    req.headersCache = req.powReq.getHeaders()
    req.headersFetched = true
  return some(req.headersCache)

proc getHeader*(req: var Request, key: string): Option[string] =
  let headers = req.getHeaders()
  if headers.isSome and headers.get.hasKey(key):
    return some($(headers.get[key]))
  none(string)

proc findHeader*(req: Request, name: string): string =
  let h = req.powReq.getHeaders()
  if h.hasKey(name):
    return $h[name]
  ""

proc removeHeader*(req: var Request, name: string) = discard
proc addHeader*(req: var Request, name, value: string) = discard
proc clearHeaders*(req: var Request) =
  req.headers = none(HttpHeaders)
  req.headersFetched = false

proc getMethod*(req: var Request): HttpMethod = req.httpMethod

proc getQuery*(req: var Request): TableRef[string, string] =
  if req.uriQuery != nil:
    return req.uriQuery
  let query = decodeQuery(req.uri.query).toSeq()
  var queryTable = newTable[string, string]()
  if query.len > 0:
    for q in query:
      queryTable[q[0]] = q[1]
  result = queryTable
  req.uriQuery = result

proc parseRangeHeader(rangeHeader: string, fileSize: int): Option[(int, int)] =
  var start, finish: int
  if rangeHeader.startsWith("bytes="):
    let rangePart = rangeHeader[6..^1].strip()
    if rangePart.scanf("$i-$i", start, finish):
      if start >= 0 and finish >= start and finish < fileSize:
        return some((start, finish))
    elif rangePart.scanf("$i-", start):
      if start >= 0 and start < fileSize:
        return some((start, fileSize - 1))
  none((int, int))

proc streamFile*(req: var Request, filePath: string,
            resHeaders: HttpHeaders = nil) =
  if resHeaders != nil:
    for k, v in resHeaders:
      req.powRes.header(k, v)
  req.powRes.streamFile(filePath, req.powReq)

proc sendFile*(req: var Request, filePath: string, resHeaders: HttpHeaders) =
  if resHeaders != nil:
    for k, v in resHeaders:
      req.powRes.header(k, v)
  req.powRes.sendFile(filePath, req.powReq, closeConn = false, contentDisposition = false)

proc sendFile*(req: var Request, bytes: seq[uint8], resHeaders: HttpHeaders) =
  if resHeaders != nil:
    for k, v in resHeaders:
      req.powRes.header(k, v)
  req.powRes.send(cast[string](bytes))

proc getBodyStream*(req: var Request): BodyStream =
  BodyStream(bodyBytes: req.powReq.getBody(), readOffset: 0)

proc readChunk*(stream: var BodyStream, maxLen: int): string =
  let available = stream.bodyBytes.len - stream.readOffset
  if available <= 0: return ""
  let toRead = min(available, maxLen)
  result = newString(toRead)
  copyMem(addr result[0], addr stream.bodyBytes[stream.readOffset], toRead)
  stream.readOffset += toRead

proc peekChunk*(stream: BodyStream, maxLen: int): (pointer, int) =
  let available = stream.bodyBytes.len - stream.readOffset
  if available <= 0: return (nil, 0)
  let toRead = min(available, maxLen)
  (addr stream.bodyBytes[stream.readOffset], toRead)

proc drainChunk*(stream: var BodyStream, len: int) =
  let available = stream.bodyBytes.len - stream.readOffset
  stream.readOffset += min(len, available)

proc runServer*(onRequest: OnRequest,
            startupCallback: StartupCallback, port = Port(3000)) =
  var server = newWebServer(port)
  server.start(onRequest, startupCallback)

proc addEvent*(server: WebServer,
    callback: proc(fd: cint, events: cshort, arg: pointer){.cdecl.}) = discard
proc addCallback*(server: WebServer, path: string,
    callback: OnRequestLowLevel) = discard
proc addCallback*(httpServer: pointer, path: string,
    callback: OnRequestLowLevel) = discard
proc registerCallback*(server: WebServer, path: string,
    callback: OnRequestLowLevel) = discard
proc unregisterCallback*(server: WebServer, path: string) = discard
