#
# Supranim is a high-performance web framework for building
# web applications and microservices in Nim
# 
#   (c) 2026 LGPL-v3-or-later License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#

import std/[os, posix, tables, httpcore, options,
           uri, strutils, strscans, sequtils, cpuinfo, locks]
import pkg/powpow as pw
import supranim/support/http
from std/net import Port, `$`

type
  OnRequestLowLevel* = proc(req: pointer, arg: pointer) {.cdecl, gcsafe.}
  StartupCallback* = proc() {.gcsafe.}

type
  WebServer* = ref object
    port*: Port
    enableMultiThreading*: bool
    powServer: pw.HttpServer
    powMultiServer: pw.MultiThreadHttpServer
    callbackTable: TableRef[string, OnRequestLowLevel]
    callbackLock: Lock

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
  ## Create a new WebServer backed by PowPow
  new(result)
  result.port = port
  result.enableMultiThreading = false
  result.callbackTable = newTable[string, OnRequestLowLevel]()
  initLock(result.callbackLock)

proc newWebServer*(port: Port = Port(8080), enableMultiThreading: bool): WebServer =
  ## Create a new multi-threaded WebServer backed by PowPow
  new(result)
  result.port = port
  result.enableMultiThreading = enableMultiThreading
  result.callbackTable = newTable[string, OnRequestLowLevel]()
  initLock(result.callbackLock)

proc start*(server: WebServer) =
  ## Start a WebServer
  var dummy = pw.newHttpServer()
  dummy.start(nil, server.port)

proc start*(server: WebServer, onRequest: OnRequest,
              startupCallback: StartupCallback = nil) =
  ## Start the PowPow WebServer 
  server.powServer = pw.newHttpServer()
  if startupCallback != nil:
    startupCallback()
  server.powServer.handler =
    proc(req: pw.HttpRequest, res: pw.HttpResponse) {.gcsafe.} =
      let normPath = normalizeCallbackPath(req.getPath())
      var cbFound: OnRequestLowLevel = nil
      acquire(server.callbackLock)
      if server.callbackTable.hasKey(normPath):
        cbFound = server.callbackTable[normPath]
      release(server.callbackLock)
      if cbFound != nil:
        cbFound(cast[pointer](req), cast[pointer](res))
        return
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

proc start*(server: WebServer, onRequest: OnRequest,
              startupCallback: StartupCallback,
              threads: int) =
  ## Start the PowPow webserver for a specific number of `threads` 
  when not compileOption("threads"):
    {.error: "Multi-threaded Supranim requires threads support. Use `--threads:on`".}
  let nThreads = if threads > 0: threads else: countProcessors()
  server.powMultiServer = pw.newMultiThreadHttpServer(nThreads)
  if startupCallback != nil:
    startupCallback()
  server.powMultiServer.start(
    proc(req: pw.HttpRequest, res: pw.HttpResponse) {.gcsafe.} =
      let normPath = normalizeCallbackPath(req.getPath())
      var cbFound: OnRequestLowLevel = nil
      acquire(server.callbackLock)
      if server.callbackTable.hasKey(normPath):
        cbFound = server.callbackTable[normPath]
      release(server.callbackLock)
      if cbFound != nil:
        cbFound(cast[pointer](req), cast[pointer](res))
        return
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
  ## Sends an HTTP response with a numeric status code.
  ## 
  ## Applies any additional headers and delegates to powpow's
  ## `HttpResponse.send`. Guards against double-sends via
  ## `responseSent`.
  if req.responseSent: return
  req.responseSent = true
  if httpHeaders != nil:
    for k, v in httpHeaders:
      req.powRes.header(k, v)
  req.powRes.status(HttpCode(code)).send(body)

proc send*(req: var Request, code: int, httpHeaders: HttpHeaders = nil) =
  ## Sends an HTTP response with a numeric status code and no body.
  send(req, code, "", httpHeaders)

proc send*(req: var Request, code: HttpCode, body: string, httpHeaders: HttpHeaders = nil) =
  ## Sends an HTTP response using the `HttpCode` enum for the status.
  req.send(code.int, body, httpHeaders)

proc startChunk*(req: Request) =
  ## Begins a chunked HTTP response. No-op in powpow mode
  ## (powpow always uses `Content-Length` framing).
  discard

proc startPartialChunk*(req: Request) =
  ## Begins a partial-content chunked response for HTTP 206.
  ## No-op in powpow mode (powpow handles range requests
  ## natively in `sendFile` / `streamFile`).
  discard

proc endChunk*(req: Request) =
  ## Ends a chunked HTTP response. No-op in powpow mode.
  discard

template withChunks*(reqInstance: Request, httpHeaders: HttpHeaders, body) {.inject.} =
  ## Wraps a block as a chunked response. In powpow mode the body
  ## executes directly (powpow always uses Content-Length framing).
  body

proc sendChunk*(req: Request, data: string) =
  ## Sends a chunk of data. In powpow mode this sends a complete
  ## HTTP 200 response with the provided data as the full body.
  req.powRes.status(Http200).send(data)

proc getIp*(req: var Request): string =
  ## Retrieve the IP of a `Request`
  req.clientIp

proc getBody*(req: var Request): Option[string] =
  ## Retrieve body for a `Request`
  if req.body.isSome:
    return req.body
  let b = req.powReq.getBodyString()
  req.body = some(b)
  return req.body

proc dropRequest*(req: var Request) =
  ## Drop the provided `Request`
  req.raw = nil
  req.responseSent = true

proc getOutputHeaders*(req: Request): string =
  ## Retrieves the response headers as a raw string.
  ## Not supported in powpow mode — returns empty string.
  ""

proc getHeaders*(req: var Request): Option[HttpHeaders] =
  ## Lazily retrieves the request headers. On first access the
  ## headers are materialised from powpow's parser buffer and
  ## cached for subsequent calls.
  if not req.headersFetched:
    req.headersCache = req.powReq.getHeaders()
    req.headersFetched = true
  return some(req.headersCache)

proc getHeader*(req: var Request, key: string): Option[string] =
  ## Retrieves a single request header by name.
  let headers = req.getHeaders()
  if headers.isSome and headers.get.hasKey(key):
    return some($(headers.get[key]))
  none(string)

proc findHeader*(req: Request, name: string): string =
  ## Low-level header lookup using powpow's parser directly.
  ## Returns empty string if the header is not present, without
  ## materialising the full headers table.
  let h = req.powReq.getHeaders()
  if h.hasKey(name):
    return $h[name]
  ""

proc removeHeader*(req: var Request, name: string) =
  ## Removes a header from the request. No-op in powpow mode
  ## (headers are parsed once from the buffer).
  discard

proc addHeader*(req: var Request, name, value: string) =
  ## Adds a header to the request. No-op in powpow mode
  ## (headers are parsed once from the buffer).
  discard

proc clearHeaders*(req: var Request) =
  ## Clears all cached request headers.
  req.headers = none(HttpHeaders)
  req.headersFetched = false

proc getMethod*(req: var Request): HttpMethod =
  ## Returns the HTTP method (GET, POST, PUT, etc.) of the request.
  req.httpMethod

proc getQuery*(req: var Request): TableRef[string, string] =
  ## Lazily parses and caches the query parameters from the request URI.
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
  ## Streams a file using powpow's chunked `streamFile`, which sends
  ## 206 Partial Content with byte-range support for media seeking.
  if resHeaders != nil:
    for k, v in resHeaders:
      req.powRes.header(k, v)
  req.powRes.streamFile(filePath, req.powReq)

proc sendFile*(req: var Request, filePath: string, resHeaders: HttpHeaders) =
  ## Sends a file using powpow's zero-copy `sendFile` (sendfile syscall).
  ## Dynamically determines MIME type from file extension.
  if resHeaders != nil:
    for k, v in resHeaders:
      req.powRes.header(k, v)
  req.powRes.sendFile(filePath, req.powReq, closeConn = false, contentDisposition = false)

proc sendFile*(req: var Request, bytes: seq[uint8], resHeaders: HttpHeaders) =
  ## Sends a byte sequence as a file response. Not zero-copy;
  ## suitable for smaller in-memory assets.
  if resHeaders != nil:
    for k, v in resHeaders:
      req.powRes.header(k, v)
  req.powRes.send(cast[string](bytes))

proc getBodyStream*(req: var Request): BodyStream =
  ## Returns a `BodyStream` for reading the request body in chunks.
  ## Eagerly materialises the full body into memory from powpow's
  ## parser buffer at construction time.
  BodyStream(bodyBytes: req.powReq.getBody(), readOffset: 0)

proc readChunk*(stream: var BodyStream, maxLen: int): string =
  ## Reads up to `maxLen` bytes from the body stream.
  ## Returns an empty string when no more data is available.
  let available = stream.bodyBytes.len - stream.readOffset
  if available <= 0: return ""
  let toRead = min(available, maxLen)
  result = newString(toRead)
  copyMem(addr result[0], addr stream.bodyBytes[stream.readOffset], toRead)
  stream.readOffset += toRead

proc peekChunk*(stream: BodyStream, maxLen: int): (pointer, int) =
  ## Returns a pointer and length to the next available chunk (up to
  ## `maxLen`). No copy is performed. The pointer is valid until the
  ## next drain operation.
  let available = stream.bodyBytes.len - stream.readOffset
  if available <= 0: return (nil, 0)
  let toRead = min(available, maxLen)
  (addr stream.bodyBytes[stream.readOffset], toRead)

proc drainChunk*(stream: var BodyStream, len: int) =
  ## Advances the read cursor by `len` bytes, effectively discarding
  ## that many bytes from the stream.
  let available = stream.bodyBytes.len - stream.readOffset
  stream.readOffset += min(len, available)

proc runServer*(onRequest: OnRequest,
            startupCallback: StartupCallback, port = Port(3000)) =
  ## Convenience procedure that creates a single-threaded WebServer,
  ## binds it to the given `port`, and starts the event loop.
  var server = newWebServer(port)
  server.start(onRequest, startupCallback)

proc addEvent*(server: WebServer,
    callback: proc(fd: cint, events: cshort, arg: pointer){.cdecl, gcsafe.}) =
  ## Adds a custom event to the server's event loop.
  ## 
  ## Allows you to integrate custom file descriptor
  ## events (e.g. for WebSockets or timers) into the same event loop as
  ## the HTTP server. Internally creates a 30ms interval timer on
  ## powpow's timer wheel. In multi-threaded mode this is a no-op
  ## (each worker owns its own loop).
  if server.powServer != nil:
    let loop = server.powServer.getLoop()
    let cb = callback
    discard loop.addInterval(30) do (id: int) {.gcsafe.}:
      cb(-1, 0, nil)

proc addCallback*(server: WebServer, path: string,
    callback: OnRequestLowLevel) =
  ## Adds a low-level callback for a specific request path.
  ## 
  ## When a request with a matching path is received, the low-level
  ## callback is invoked directly instead of going through the normal
  ## supranim routing pipeline. The callback receives the raw powpow
  ## `HttpRequest` as an opaque pointer — cast it back with
  ## `cast[ptr pw.HttpRequest](req)`.
  ## 
  ## Note: Path matching uses normalized paths (trailing slashes
  ## removed, etc.).
  let normalized = normalizeCallbackPath(path)
  acquire(server.callbackLock)
  server.callbackTable[normalized] = callback
  release(server.callbackLock)

proc registerCallback*(server: WebServer, path: string,
    callback: OnRequestLowLevel) =
  ## Registers a low-level callback in a thread-safe manner.
  ## 
  ## Same as `addCallback` but with explicit thread-safety guarantees.
  ## The callback is stored in the per-server `callbackTable` and
  ## checked on every request before the normal handler runs.
  let normalized = normalizeCallbackPath(path)
  acquire(server.callbackLock)
  server.callbackTable[normalized] = callback
  release(server.callbackLock)

proc unregisterCallback*(server: WebServer, path: string) =
  ## Unregisters a previously registered low-level callback.
  ## 
  ## After this call, requests to the given path will be handled by
  ## the normal supranim routing pipeline again.
  let normalized = normalizeCallbackPath(path)
  acquire(server.callbackLock)
  if server.callbackTable.hasKey(normalized):
    server.callbackTable.del(normalized)
  release(server.callbackLock)
