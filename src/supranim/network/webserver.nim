#
# Supranim is a high-performance web framework for building
# web applications and microservices in Nim
# 
#   (c) 2026 LGPL-v3-or-later License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#

import std/[os, posix, tables, httpcore, options,
          uri, strutils, strscans, sequtils, atomics]

import pkg/threading/rwlock
import pkg/libevent/bindings/[http, event, buffer, threaded, listener]
import ../support/http
from std/net import Port, `$`

export evhttp_request, threaded, evhttp_request_get_connection

# for some reason the emit pragma won't work if placed in
# bindings/http.nim so will put it here
{.emit: """
  #include <sys/queue.h>
  #include <event2/http.h>
  #include <event2/keyvalq_struct.h>

  // Function to iterate over evkeyvalq and call a callback for each key-value pair
  void nim_evkeyvalq_iterate(const struct evkeyvalq* headers, void (*cb)(char*, char*, void*), void* arg) {
    struct evkeyval* header;
    TAILQ_FOREACH(header, headers, next) {
      cb(header->key, header->value, arg);
    }
  }
""".}

## This module implements a high-performance HTTP server using the Libevent library.
## 
## The server is designed to be used in a non-blocking, event-driven manner, allowing for
## high concurrency and efficient resource usage. It also includes support for HTTP Range requests
## when streaming files, enabling partial content delivery for large files.
## 
## The API is flexible and can be used for simple use cases with a single request handler,
## or more complex scenarios with multiple callbacks for different paths.

type
  WebServer* = ref object
    ## Represents an HTTP server.
    base*: ptr event_base
      ## The underlying event base.
    httpServer*: ptr evhttp
      ## The underlying evhttp server.
    port*: Port
      ## The port the server listens on.
    otherOnRequestCallbacks*: Table[string, OnRequestLowLevel]
      ## Store other path-specific callbacks. This table is used to inject
      ## low-level callbacks for specific paths. It works in both single-threaded and multi-threaded modes.
    enableMultiThreading*: bool
      # Whether the server is running in multi-threaded mode. This affects how
      # callbacks are stored and invoked.
    workerHttpServers*: seq[ptr evhttp]
      # In multi-threaded mode, we need to keep track of each worker's HTTP server
      # so that we can register callbacks on them when new callbacks are added at runtime.

  Request* = object
    ## Represents an HTTP request.
    httpMethod*: EvhttpCmdType
      ## The HTTP method (GET, POST, etc.).
    raw*: ptr evhttp_request
      ## The underlying evhttp_request pointer.
    clientIp: string
      ## The client's IP address.
    path*: string
      ## The request path.
    uri*: Uri
      ## The parsed URI object.
    uriQuery*: TableRef[string, string]
      ## Lazily initialized query parameters from the URI.
    headers*: Option[HttpHeaders]
      ## The request headers (lazily initialized).
    body*: Option[string]
      ## The request body (lazily initialized).
    routeParams*: Table[string, string]
      ## The route parameters extracted from the URL.
    responseSent*: bool
      ## Whether a response has already been sent for this request.
      ## This is used to prevent multiple responses.
  
  OnRequestLowLevel* = proc(req: ptr evhttp_request, arg: pointer) {.cdecl.}
    ## Low-level callback type for handling HTTP requests directly with evhttp_request.

  StartupCallback* = proc() {.gcsafe.}
    ## Callback type for server startup (optional).

var webWorkerLocker = createRwLock()
var runtimeLowLevelCallbacks = initTable[string, OnRequestLowLevel]()
var gLibeventThreadingInit: Atomic[bool]

proc ensureLibeventThreading() =
  if not gLibeventThreadingInit.load(moAcquire):
    doAssert evthread_use_pthreads() == 0, "evthread_use_pthreads failed"
    gLibeventThreadingInit.store(true, moRelease)

proc normalizeCallbackPath(path: string): string {.inline.} =
  let p = if path.len == 0: "/" else: path
  normalizePath(p)

when defined supranimUseGlobalOnRequest:
  type
    OnRequest* = proc(req: var Request)
      ## Callback type for handling HTTP requests.
else:
  type
    OnRequest* = proc(req: var Request) {.nimcall.}
      ## Callback type for handling HTTP requests.

type
  WorkerCtx = object
    # Context passed to worker threads in pool mode
    port: Port
      # The port the worker should listen on
    listenFd: cint
      # The shared listening socket file descriptor
    when not defined(supranimUseGlobalOnRequest):
      handler: OnRequest
        # The request handler for this worker (if not using global handler)
    otherOnRequestCallbacks: Table[string, OnRequestLowLevel]
      # When using multi-threaded mode, we need to copy
      # the path-specific callbacks to each worker's context

#
# fwd declarations
#
proc addCallback*(server: WebServer, path: string, callback: OnRequestLowLevel)
proc addCallback*(httpServer: ptr evhttp, path: string, callback: OnRequestLowLevel)

proc applyAllowedMethods(httpServer: ptr evhttp) =
  let allowedMethods = (uint16(EVHTTP_REQ_GET) or uint16(EVHTTP_REQ_POST) or
    uint16(EVHTTP_REQ_HEAD) or uint16(EVHTTP_REQ_PUT) or
    uint16(EVHTTP_REQ_DELETE) or uint16(EVHTTP_REQ_OPTIONS) or
    uint16(EVHTTP_REQ_PATCH) or uint16(EVHTTP_REQ_TRACE) or
    uint16(EVHTTP_REQ_CONNECT))
  evhttp_set_allowed_methods(httpServer, allowedMethods)

proc noopListenerCb(listener: ptr evconnlistener, fd: evutil_socket_t,
                     res: ptr SockAddr, socklen: cint, user_arg: pointer) {.cdecl.} = discard

proc newReusePortListener(base: ptr event_base,
          httpServer: ptr evhttp, port: Port): ptr evconnlistener =
  var sin: Sockaddr_in
  zeroMem(addr sin, sizeof(sin))
  sin.sin_family = typeof(sin.sin_family)(AF_INET)
  sin.sin_port = htons(port.uint16)
  sin.sin_addr.s_addr = htonl(INADDR_ANY.uint32)

  let flags =
    LEV_OPT_CLOSE_ON_FREE or
    LEV_OPT_REUSEABLE or
    LEV_OPT_REUSEABLE_PORT

  result = evconnlistener_new_bind(
    base,
    noopListenerCb, nil,   # <-- must not be nil
    flags,
    -1,
    cast[ptr SockAddr](addr sin),
    cint(sizeof(sin))
  )
  doAssert result != nil, "evconnlistener_new_bind failed"
  doAssert evhttp_bind_listener(httpServer, result) != nil, "evhttp_bind_listener failed"

proc newWebServer*(port: Port = Port(8080)): WebServer =
  ## Creates a new WebServer instance.
  ensureLibeventThreading()
  new(result)
  result.base = event_base_new()
  discard evthread_make_base_notifiable(result.base)
  assert result.base != nil
  
  # Create HTTP server
  result.httpServer = evhttp_new(result.base)
  assert result.httpServer != nil
  applyAllowedMethods(result.httpServer)
  result.port = port

proc newWebServer*(port: Port = Port(8080), enableMultiThreading: bool): WebServer =
  ## Creates a new WebServer instance with multi-threading support.
  ## When `enableMultiThreading` is true, the server will be started in a thread pool mode
  ## which allows handling multiple requests concurrently across multiple CPU cores.
  ## 
  ## This is recommended for production use. For development, you can use the
  ## single-threaded version for simplicity.
  # ensureLibeventThreading()
  ensureLibeventThreading()
  new(result)
  
  # `enableMultiThreading` is just a marker here
  # that will prevent initialize the default `evhttp` server.
  # the actual multi-threaded behavior is determined by
  # which `start` proc is called.
  result.enableMultiThreading = true
  result.port = port
  # Note: We do not create the listener here because in multi-threaded
  # mode we need to share the listening socket among worker threads.

when defined supranimUseGlobalOnRequest:
  var appOnRequest {.global.}: OnRequest # global request handler

# forward decl
proc send*(req: var Request, code: int, body: string, httpHeaders: HttpHeaders = nil)

proc initialOnRequest(raw: ptr evhttp_request, arg: pointer) {.cdecl.} =
  # This is the initial request handler that is registered
  # with libevent. It is responsible for parsing the incoming request,
  # checking if there are any low-level callbacks registered for the request path,
  # and then invoking the appropriate callback (either low-level or high-level).
  let uriRaw = $evhttp_request_get_uri(raw)
  let pathOnly =
    if uriRaw.len == 0: "/"
    else: uriRaw.split('?', 1)[0]
  let normPath = normalizeCallbackPath(pathOnly)

  readWith webWorkerLocker:
    if runtimeLowLevelCallbacks.hasKey(normPath):
      # let cb = runtimeLowLevelCallbacks[normPath]
      # if cb != nil:
      #   cb(raw, nil)
      return
  
  let host = evhttp_request_get_host(raw)
  var req = Request(
    raw: raw,
    clientIp: (
      if host != nil: $evhttp_request_get_host(raw)
      else: "unknown"
    ),
    httpMethod: evhttp_request_get_command(raw)
  )

  # parse the path and URI
  let evUri: ptr evhttp_uri = evhttp_request_get_evhttp_uri(raw)
  if evUri != nil:
    let uriPath = $evhttp_request_get_uri(raw)
    let normPath = normalizePath(if uriPath.len == 0: "/" else: uriPath)
    if uriPath != normPath:
      # redirect to normalized path if it differs (e.g. remove trailing slash)
      let headers = newHttpHeaders({"Location": normPath})
      req.send(301, "", headers)
      return
    req.path = normPath
    req.uri = uri.parseUri(normPath)
    req.uri.scheme = $evhttp_uri_get_scheme(evUri)
    req.uri.query = $evhttp_uri_get_query(evUri)
    req.uri.anchor = $evhttp_uri_get_fragment(evUri)
  
  # Call the user-defined request handler
  when defined supranimUseGlobalOnRequest:
    if likely(appOnRequest != nil):
      appOnRequest(req)
    else:
      req.send(500, "No request handler")
  else:
    let handler = cast[OnRequest](arg)
    if likely(handler != nil):
      handler(req)
    else: req.send(500, "No request handler")

proc bindSharedSocket(port: Port): cint =
  let fd = socket(AF_INET, SOCK_STREAM, 0)
  doAssert fd.int >= 0, "socket() failed"

  var one: cint = 1
  doAssert setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, addr one, SockLen(sizeof(one))) == 0,
    "setsockopt(SO_REUSEADDR) failed"

  var sin: Sockaddr_in
  zeroMem(addr sin, sizeof(sin))
  sin.sin_family = typeof(sin.sin_family)(AF_INET)
  sin.sin_port = htons(port.uint16)
  sin.sin_addr.s_addr = htonl(INADDR_ANY.uint32)

  doAssert bindSocket(fd, cast[ptr SockAddr](addr sin), SockLen(sizeof(sin))) == 0, "bind() failed"
  doAssert listen(fd, 10240) == 0, "listen() failed"

  let flags = fcntl(fd, F_GETFL, 0)
  doAssert flags >= 0, "fcntl(F_GETFL) failed"
  doAssert fcntl(fd, F_SETFL, flags or O_NONBLOCK) == 0, "fcntl(F_SETFL,O_NONBLOCK) failed"

  result = fd.cint

proc webWorker(arg: (ptr WorkerCtx, StartupCallback)) {.thread.} =
  # Worker thread entry point. Each worker creates its own event base and HTTP server,
  # but they all share the same listening socket for accepting connections.
  #
  # This allows us to handle requests concurrently across multiple threads while still
  # using the efficient event-driven model of libevent.
  # 
  # Basically, we're creating a pool of worker threads that all listen on the same port
  # and libevent will distribute incoming connections among them. Each worker thread runs its own
  # event loop and handles requests independently, allowing us to take advantage of multiple CPU cores
  let (ctxPtr, startupCallback) = arg
  let ctx = ctxPtr[]

  var base = event_base_new()
  doAssert base != nil
  discard evthread_make_base_notifiable(base)

  var httpServer = evhttp_new(base)
  doAssert httpServer != nil

  # Set the same allowed methods for each worker's HTTP server
  applyAllowedMethods(httpServer)
  doAssert evhttp_accept_socket(httpServer, ctx.listenFd) == 0, "evhttp_accept_socket failed"
  
  # the startup callback contains threadvar initialization
  # code that needs to run in the context of each worker thread
  if startupCallback != nil:
    startupCallback()

  when defined(supranimUseGlobalOnRequest):
    evhttp_set_gencb(httpServer, initialOnRequest, nil)
  else:
    evhttp_set_gencb(httpServer, initialOnRequest, cast[pointer](ctx.handler))
  
  # register any additional path-specific callbacks for this worker
  readWith webWorkerLocker:
    # not sure if we need to lock here since the server should
    # not be accepting requests yet, but just to be safe
    for path, callback in ctx.otherOnRequestCallbacks:
      discard evhttp_set_cb(httpServer, path.cstring, callback, nil)

  # Start the event loop for this worker thread
  discard event_base_dispatch(base)

  evhttp_free(httpServer)
  event_base_free(base)
  dealloc(ctxPtr)

proc start*(server: var WebServer) =
  ## Start the web server with default no-op request handler.
  assert server.httpServer != nil # ensure server is initialized
  assert evhttp_bind_socket(server.httpServer, "0.0.0.0", server.port.uint16) == 0
  discard event_base_dispatch(server.base) # or event_base_loop(base, 0)

proc start*(server: var WebServer, onRequest: OnRequest,
              startupCallback: StartupCallback = nil) =
  ## Starts the web server event loop.
  assert server.httpServer != nil # ensure server is initialized

  if startupCallback != nil:
    startupCallback() # TODO move to initialRequest?

  assert evhttp_bind_socket(server.httpServer, "0.0.0.0", server.port.uint16) == 0
  when defined(supranimUseGlobalOnRequest):
    appOnRequest = onRequest
    evhttp_set_gencb(server.httpServer, initialOnRequest, nil)
  else:
    evhttp_set_gencb(server.httpServer, initialOnRequest, cast[pointer](onRequest))
  assert event_base_dispatch(server.base) > -1
  evhttp_free(server.httpServer)
  event_base_free(server.base)

proc start*(server: var WebServer, onRequest: OnRequest,
              startupCallback: StartupCallback,
              threads: int) =
  ## Starts the web server event loop in a thread pool mode for handling
  ## requests concurrently. This is suitable for production use to take
  ## advantage of multiple CPU cores and handle high traffic efficiently.
  assert server.httpServer == nil, 
    "Use newWebServer(port, enableMultiThreading=true) to create a server that supports multi-threading"
  when not compileOption("threads"):
    # Nim 2.x enables threads by default, but if for some reason
    # threads are not enabled we cannot run in pool mode
    {.error: "Mutli-threaded Supranim requires threads support. Use `--threads:on`".}

  # ensureLibeventThreading()
  let sharedFd = bindSharedSocket(server.port)
  when defined(supranimUseGlobalOnRequest):
    appOnRequest = onRequest
    
  var workers = newSeq[Thread[(ptr WorkerCtx, StartupCallback)]](threads - 1)
  for i in 0 ..< workers.len:
    let ctx = cast[ptr WorkerCtx](alloc0(sizeof(WorkerCtx)))
    ctx.port = server.port
    ctx.listenFd = sharedFd
    ctx.otherOnRequestCallbacks = server.otherOnRequestCallbacks
    when not defined(supranimUseGlobalOnRequest):
      ctx.handler = onRequest
    createThread(workers[i], webWorker, (ctx, startupCallback))

  let mainCtx = cast[ptr WorkerCtx](alloc0(sizeof(WorkerCtx)))
  mainCtx.port = server.port
  mainCtx.listenFd = sharedFd
  mainCtx.otherOnRequestCallbacks = move server.otherOnRequestCallbacks
  when not defined(supranimUseGlobalOnRequest):
    mainCtx.handler = onRequest

  # start a web worker in the main thread
  webWorker((mainCtx, startupCallback))
  
  for t in workers:
    joinThread(t)
  discard close(sharedFd)

proc setOutHeader(headers: ptr evkeyvalq, name, value: string) =
  discard evhttp_remove_header(headers, name.cstring) # ignore if absent
  assert evhttp_add_header(headers, name.cstring, value.cstring) == 0

proc send*(req: ptr evhttp_request, code: int, body: string, httpHeaders: HttpHeaders = nil) =
  ## Sends an HTTP response directly using evhttp_request.
  let headers = evhttp_request_get_output_headers(req)
  if headers != nil and httpHeaders != nil:
    for k, v in httpHeaders:
      setOutHeader(headers, k, v)
  let buf = evhttp_request_get_output_buffer(req)
  assert buf != nil
  # ensure clean buffer per request
  discard evbuffer_drain(buf, evbuffer_get_length(buf))
  if body.len > 0:
    discard evbuffer_add(buf, body.cstring, body.len.csize_t)

  # libevent computes framing from buf.
  evhttp_send_reply(req, code.cint, nil, buf)

#
# High-level API for handling requests and sending responses
#
proc send*(req: var Request, code: int, body: string, httpHeaders: HttpHeaders = nil) =
  ## Sends an HTTP response.
  req.raw.send(code, body, httpHeaders)
  req.responseSent = true

proc send*(req: var Request, code: int, httpHeaders: HttpHeaders = nil) =
  # Route all no-body replies through the same framing path
  send(req, code, "", httpHeaders)

proc send*(req: var Request, code: HttpCode, body: string, httpHeaders: HttpHeaders = nil) =
  ## Sends an HTTP response using HttpCode enum.
  req.send(code.int, body, httpHeaders)

proc startChunk*(req: Request) =
  ## Starts a chunked HTTP response.
  evhttp_send_reply_start(req.raw, HTTP_OK, "OK")

proc startPartialChunk*(req: Request) =
  ## Starts a partial content chunked HTTP response.
  ## Indicates that the response is for a partial content request (HTTP 206).
  evhttp_send_reply_start(req.raw, 206, "Partial Content")

proc endChunk*(req: Request) =
  ## Ends a chunked HTTP response.
  evhttp_send_reply_end(req.raw)

template withChunks*(reqInstance: Request, httpHeaders: HttpHeaders, body) {.inject.} =
  ## Enables chunked transfer encoding for the response.
  if httpHeaders != nil:
    let headers = evhttp_request_get_output_headers(reqInstance.raw)
    for k, v in httpHeaders:
      assert evhttp_add_header(headers, k.cstring, v.cstring) == 0
  reqInstance.startChunk()
  body # execute the body
  reqInstance.endChunk() # then end the chunked response

proc sendChunk*(req: Request, data: string) =
  ## Sends a chunked HTTP response.
  let buf = evbuffer_new()
  discard evbuffer_add(buf, data.cstring, data.len.csize_t)
  evhttp_send_reply_chunk(req.raw, buf)
  evbuffer_free(buf)

proc getIp*(req: var Request): string =
  ## Retrieves the IP address from request
  result = req.clientIp

proc getBody*(req: var Request): Option[string] =
  ## Retrieves the body from `Request`
  ## Lazily initializes the body on first access. Then
  ## caches it for future accesses.
  if req.body.isSome:
    return req.body # return cached body if already fetched
  # fetch body from evhttp_request
  let buf = evhttp_request_get_input_buffer(req.raw)
  if buf != nil:
    let len = evbuffer_get_length(buf)
    if len > 0:
      var data = newString(len)
      discard evbuffer_copyout(buf, addr(data[0]), len.csize_t)
      req.body = some(data)
  return req.body

proc dropRequest*(req: var Request) =
  ## Drop the request by closing the connection without sending a response.
  ## This can be used in cases where you want to silently ignore a request without responding
  # let conn = evhttp_request_get_connection(req.raw)
  # if conn != nil:
  # evhttp_connection_free(conn) # don't free the connection directly, just close the socket
  req.raw = nil # mark as dropped
  req.responseSent = true

#
# Header high-level bindings
#
proc getOutputHeaders*(req: Request): string =
  let headers = evhttp_request_get_output_headers(req.raw)
  var res = ""
  proc cb(key, value: cstring, arg: pointer) {.cdecl.} =
    var str = cast[ptr string](arg)
    str[].add($key & ": " & $value & "\r\n")
  nim_evkeyvalq_iterate(headers, cb, addr(res))
  return res

proc getHeaders*(req: var Request): Option[HttpHeaders] =
  ## Retrieves the headers from the HTTP request as a Table.
  ## Lazily initializes the headers on first access. Then
  ## caches them for future accesses.
  if req.headers.isSome:
    return req.headers
  
  # Define a local proc to collect headers into the table
  # this will be called by nim_evkeyvalq_iterate
  var headers = newSeq[(string, string)]()
  proc collect(key, value: cstring, arg: pointer) {.cdecl.} =
    let headersPtr = cast[ptr seq[(string, string)]](arg)
    headersPtr[].add(($key, $value))

  nim_evkeyvalq_iterate(
    evhttp_request_get_input_headers(req.raw),
    collect, addr(headers)
  )
  if headers.len > 0:
    req.headers = some(newHttpHeaders(headers))
  reset(headers)
  return req.headers

proc getHeader*(req: var Request, key: string): Option[string] =
  ## Returns return a header from Request
  let headers = req.getHeaders().get()
  if headers.hasKey(key):
    return some($(headers[key]))
  none(string)

proc findHeader*(req: Request, name: string): string =
  ## Use the lower-level C API to check if a header exists.
  ## This is more efficient than fetching all headers.
  ## This does not update any cached headers in `req.headers`.
  result = $(evhttp_find_header(evhttp_request_get_input_headers(req.raw), name.cstring))

proc removeHeader*(req: var Request, name: string) =
  ## Removes a header from the request. This uses the lower-level C API.
  ## Note: This does update existing caches in req.headers.
  assert evhttp_remove_header(evhttp_request_get_input_headers(req.raw), name.cstring) == 0
  if req.headers.isSome:
    req.headers.get().del(name)

proc addHeader*(req: var Request, name, value: string) =
  ## Sets a header in the request. This uses the lower-level C API.
  ## Note: This does overwrite existing caches in req.headers.
  assert evhttp_add_header(evhttp_request_get_input_headers(req.raw), name.cstring, value.cstring) == 0
  if req.headers.isSome:
    req.headers.get()[name] = value

proc clearHeaders*(req: var Request) =
  ## Clears all headers from the request. This uses the lower-level C API.
  ## Note: This also clears the cached headers table.
  evhttp_clear_headers(evhttp_request_get_input_headers(req.raw))
  req.headers = none(HttpHeaders)

proc getMethod*(req: var Request): HttpMethod =
  ## Maps the EvhttpCmdType to a more user-friendly HttpMethod enum.
  ## To avoid the mapping overhead use req.httpMethod directly.
  result = case req.httpMethod
    of EVHTTP_REQ_GET: HttpMethod.HttpGet
    of EVHTTP_REQ_POST: HttpMethod.HttpPost
    of EVHTTP_REQ_HEAD: HttpMethod.HttpHead
    of EVHTTP_REQ_PUT: HttpMethod.HttpPut
    of EVHTTP_REQ_DELETE: HttpMethod.HttpDelete
    of EVHTTP_REQ_OPTIONS: HttpMethod.HttpOptions
    of EVHTTP_REQ_TRACE: HttpMethod.HttpTrace
    of EVHTTP_REQ_CONNECT: HttpMethod.HttpConnect
    of EVHTTP_REQ_PATCH: HttpMethod.HttpPatch

proc getQuery*(req: var Request): TableRef[string, string] =
  ## Returns the parsed query parameters from the request URI
  ## as a Table. Lazily initializes on first access. Then caches
  ## them for future accesses.
  if req.uriQuery != nil:
    return req.uriQuery
  let query = decodeQuery(req.uri.query).toSeq()
  var queryTable = newTable[string, string]()
  if query.len > 0:
    for q in query:
      queryTable[q[0]] = q[1]
  result = queryTable
  req.uriQuery = result # cache for future accesses

type
  StreamFileCtx = object
    fd: cint
    offset: int64
    fileSize: int64
    req: ptr evhttp_request
    chunkSize: int64

proc streamFileChunkCb(conn: ptr evhttp_connection, ctxPtr: pointer) {.cdecl.} =
  # Called after a chunk is sent, schedules the next chunk
  var ctx = cast[ptr StreamFileCtx](ctxPtr)
  if ctx.offset >= ctx.fileSize:
    evhttp_send_reply_end(ctx.req)
    discard close(ctx.fd)
    dealloc(ctx)
    return

  let remaining = ctx.fileSize - ctx.offset
  let thisChunk = if remaining < ctx.chunkSize: remaining else: ctx.chunkSize
  let seg = evbuffer_file_segment_new(ctx.fd, ctx.offset, thisChunk, 0)
  if seg == nil:
    evhttp_send_reply_end(ctx.req)
    discard close(ctx.fd)
    dealloc(ctx)
    return

  let buf = evhttp_request_get_output_buffer(ctx.req)
  discard evbuffer_add_file_segment(buf, seg, 0, thisChunk)
  ctx.offset += thisChunk
  
  # Schedule next chunk after this one is sent
  evhttp_send_reply_chunk_with_cb(ctx.req, buf, streamFileChunkCb, ctx)
  evbuffer_file_segment_free(seg)

proc parseRangeHeader(rangeHeader: string, fileSize: int): Option[(int, int)] =
  # Parses a Range header like "bytes=100-200" or "bytes=100-"
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

proc streamFile*(req: var Request, filePath: string, resHeaders: HttpHeaders = nil) =
  ## Streams a file over HTTP using chunked transfer encoding and zero-copy file segments.
  ## 
  ## Supports HTTP Range requests for partial content delivery.
  ## 
  ## This method is suitable for large files as it streams them in chunks.
  ## 
  ## For smaller files consider using `sendFile` which sends the entire file in one go.
  ## 
  ## Ensure to set the correct `contentType` for the file being served as it does not check the file type.
  let fd = open(filePath, O_RDONLY)
  if fd < 0:
    req.send(404, "File not found")
    return

  let fileSize = getFileSize(filePath)
  if fileSize < 0: # allow empty files
    discard close(fd)
    req.send(404, "File not found")
    return

  var rangeHeader: string
  let headersOpt = req.getHeaders()
  if headersOpt.isSome:
    let headers = headersOpt.get()
    if headers.hasKey("Range"):
      rangeHeader = headers["Range"]

  var
    rangeStart: int = 0
    rangeEnd: int = fileSize - 1
    isPartial: bool

  if rangeHeader.len > 0:
    let parsed = parseRangeHeader(rangeHeader, fileSize)
    if parsed.isSome:
      (rangeStart, rangeEnd) = parsed.get()
      isPartial = true
    else:
      # Invalid range: respond with 416 and do not stream
      discard close(fd)
      var headers = newHttpHeaders({
        "Content-Range": "bytes */" & $fileSize
      })
      req.send(416, "Requested Range Not Satisfiable", headers)
      return

  let streamLength = rangeEnd - rangeStart + 1
  if streamLength <= 0 or rangeStart >= fileSize or rangeEnd >= fileSize:
    # Defensive: also check for impossible ranges
    discard close(fd)
    var headers = newHttpHeaders({
      "Content-Range": "bytes */" & $fileSize
    })
    req.send(416, "Requested Range Not Satisfiable", headers)
    return

  # Compose headers: start with user headers, then add/overwrite required ones
  var resHeaders = if resHeaders != nil: resHeaders else: newHttpHeaders()
  assert resHeaders.hasKey("Content-Type"), "Content-Type header must be set"
  resHeaders["Accept-Ranges"] = "bytes"
  if isPartial:
    resHeaders["Content-Range"] = "bytes " & $rangeStart & "-" & $rangeEnd & "/" & $fileSize

  let outHeaders = evhttp_request_get_output_headers(req.raw)
  for k, v in resHeaders:
    discard evhttp_add_header(outHeaders, k.cstring, v.cstring)

  # Use correct status for chunked response
  if isPartial:
    req.startPartialChunk()
  else:
    req.startChunk()

  # Allocate context for streaming
  let ctx = cast[ptr StreamFileCtx](alloc0(sizeof(StreamFileCtx)))
  ctx[].fd = fd
  ctx[].offset = rangeStart.int64
  ctx[].fileSize = (rangeEnd + 1).int64 # exclusive
  ctx[].req = req.raw
  ctx[].chunkSize = 1_048_576 # 1MB # TODO make configurable
  streamFileChunkCb(nil, ctx)

proc sendFile*(req: var Request, filePath: string, resHeaders: HttpHeaders) =
  ## Sends a file as a single chunk using zero-copy.
  ## Note: Does not check for file type. Ensure to
  ## set the correct `Content-Type` header.
  let fd = open(filePath, O_RDONLY)
  if fd < 0:
    req.send(404, "File not found")
    return
  # defer: discard close(fd)
  let fileSize = getFileSize(filePath)
  if fileSize < 0: # allow empty files
    req.send(404, "File not found")
    return
  assert resHeaders.hasKey("Content-Type"), "Content-Type header must be set"
  let outHeaders = evhttp_request_get_output_headers(req.raw)
  for k, v in resHeaders:
    discard evhttp_add_header(outHeaders, k.cstring, v.cstring)

  let buf = evhttp_request_get_output_buffer(req.raw)
  discard evbuffer_add_file(buf, fd, 0, fileSize)
  evhttp_send_reply(req.raw, 200, "", buf)

proc sendFile*(req: var Request, bytes: seq[uint8], resHeaders: HttpHeaders) =
  ## Sends a byte sequence as a file response.
  ## Note: This is not zero-copy and is suitable for smaller files.
  assert resHeaders.hasKey("Content-Type"), "Content-Type header must be set"
  let outHeaders = evhttp_request_get_output_headers(req.raw)
  for k, v in resHeaders:
    discard evhttp_add_header(outHeaders, k.cstring, v.cstring)

  let buf = evhttp_request_get_output_buffer(req.raw)
  discard evbuffer_add(buf, cast[pointer](unsafeAddr bytes[0]), bytes.len.csize_t)
  evhttp_send_reply(req.raw, 200, "", buf)

type
  BodyStream* = object
    ## Represents a stream for reading the request body in chunks.
    buf: ptr Evbuffer

proc getBodyStream*(req: var Request): BodyStream =
  ## Returns a BodyStream for reading the request body in chunks.
  result.buf = evhttp_request_get_input_buffer(req.raw)

proc readChunk*(stream: var BodyStream, maxLen: int): string =
  ## Reads up to maxLen bytes from the stream.
  ## Returns empty string when no more data is available.
  if stream.buf == nil:
    return # no buffer
  
  let available = evbuffer_get_length(stream.buf).int
  if available == 0:
    return # no more data
  
  let toRead = if available < maxLen: available else: maxLen
  result = newString(toRead)
  let n = evbuffer_remove(stream.buf, addr(result[0]), toRead.csize_t)
  if n < toRead: result.setLen(n)

proc peekChunk*(stream: BodyStream, maxLen: int): (pointer, int) =
  ## Returns a pointer and length to the next available chunk (up to maxLen).
  ## No copy is performed. The pointer is only valid until the next buffer operation.
  if stream.buf == nil: return (nil, 0)
  var iov: EvbufferIovec
  let n = evbuffer_peek(stream.buf, maxLen.int64, nil, addr(iov), 1)
  if n <= 0 or iov.iov_len == 0: return (nil, 0)
  let toRead = if iov.iov_len < maxLen.csize_t: iov.iov_len else: maxLen.csize_t
  (iov.iov_base, toRead.int)

proc drainChunk*(stream: var BodyStream, len: int) =
  ## Removes len bytes from the buffer (after processing a peeked chunk).
  if stream.buf != nil and len > 0:
    discard evbuffer_drain(stream.buf, len.csize_t)

proc runServer*(onRequest: OnRequest,
            startupCallback: StartupCallback, port = Port(3000)) =
  ## Starts the HTTP server using `pkg/libevent`
  ## and runs the request handler.
  var server = newWebServer(port)
  server.start(onRequest, startupCallback)

proc addEvent*(server: WebServer, callback: proc(fd: cint, events: cshort, arg: pointer){.cdecl.}) =
  ## Adds a custom event to the server's event loop.
  ## 
  ## This allows you to integrate custom file descriptor
  ## events (e.g. for WebSockets or timers) into the same event loop as
  ## the HTTP server.
  let ev = event_new(server.base, -1, EV_PERSIST, callback, nil)
  assert ev != nil
  var timeout: event.Timeval
  timeout.tv_sec = 0
  timeout.tv_usec = 30000 # 30ms timeout to prevent hanging if something goes wrong
  assert event_add(ev, addr(timeout)) == 0

proc addCallback*(server: WebServer, path: string,
    callback: OnRequestLowLevel) =
  ## Adds a callback for a specific path. This allows
  ## you to define custom handler functions for different routes
  ## 
  ## Note: This is a lower-level API. For more complex routing consider
  ## using the Router service which provides higher-level abstractions.
  discard evhttp_set_cb(server.httpServer, path.cstring, callback, nil)

proc addCallback*(httpServer: ptr evhttp, path: string,
    callback: OnRequestLowLevel) =
  ## Adds a callback for a specific path directly to an evhttp server.
  ## 
  ## This is a lower-level API. For more complex routing consider
  ## using the Router service which provides higher-level abstractions
  discard evhttp_set_cb(httpServer, path.cstring, callback, nil)

proc registerCallback*(server: WebServer, path: string, callback: OnRequestLowLevel) =
  ## Registers a callback to WebServer
  let normalized = normalizeCallbackPath(path)

  writeWith webWorkerLocker:
    runtimeLowLevelCallbacks[normalized] = callback
    if server.enableMultiThreading:
      # keep desired routes for future workers/restarts
      server.otherOnRequestCallbacks[normalized] = callback

  if not server.enableMultiThreading:
    # optional in single-thread mode; generic dispatch already works
    server.addCallback(normalized, callback)

proc unregisterCallback*(server: WebServer, path: string) =
  ## Unregister callback safely in both single and multi-thread modes
  let normalized = normalizeCallbackPath(path)

  writeWith webWorkerLocker:
    if runtimeLowLevelCallbacks.hasKey(normalized):
      runtimeLowLevelCallbacks.del(normalized)
    if server.otherOnRequestCallbacks.hasKey(normalized):
      server.otherOnRequestCallbacks.del(normalized)

  if not server.enableMultiThreading and server.httpServer != nil:
    # clear direct libevent route if it was installed
    discard evhttp_set_cb(server.httpServer, normalized.cstring, nil, nil)
