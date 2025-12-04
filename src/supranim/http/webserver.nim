#
# Supranim is a full-featured web framework for building
# web apps & microservices in Nim.
# 
#   (c) 2025 MIT License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#

import std/[os, posix, tables, httpcore, options,
          uri, strutils, strscans, sequtils]

import pkg/libevent/bindings/[http, event, buffer, threaded, listener]
export evhttp_request, threaded

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

from std/net import Port, `$`

type
  WebServer* = ref object
    ## Represents an HTTP server.
    base*: ptr event_base
      ## The underlying event base.
    httpServer*: ptr evhttp
      ## The underlying evhttp server.
    port*: Port
      ## The port the server listens on.

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
    uriQuery*: Option[TableRef[string, string]]
      ## Lazily initialized query parameters from the URI.
    headers*: Option[HttpHeaders]
      ## The request headers (lazily initialized).
    body*: Option[string]
      ## The request body (lazily initialized).
    appData*: pointer
      ## User-defined application data (optional).

  OnRequest* = proc(req: var Request) {.nimcall.}
    ## Callback type for handling HTTP requests.
  
  StartupCallback* = proc() {.gcsafe.}
    ## Callback type for server startup (optional).

proc newWebServer*(port: Port = Port(8080)): WebServer =
  ## Creates a new WebServer instance.
  new(result)
  result.base = event_base_new()
  discard evthread_make_base_notifiable(result.base)
  assert result.base != nil
  
  # Create HTTP server
  result.httpServer = evhttp_new(result.base)
  assert result.httpServer != nil

  result.port = port

proc initialOnRequest(raw: ptr evhttp_request, arg: pointer) {.cdecl.} =
  # initialize Request object
  var req = Request(
    raw: raw,
    clientIp: (
      if evhttp_request_get_host(raw) != nil: $evhttp_request_get_host(raw)
      else: "unknown"
    ),
    httpMethod: evhttp_request_get_command(raw)
  )
  # parse the path and URI
  let uriPath = $evhttp_request_get_uri(raw)
  let evUri: ptr evhttp_uri = evhttp_request_get_evhttp_uri(raw)
  if evUri != nil:
    req.uri = uri.parseUri(uriPath)
    req.path = if uriPath.len == 0: "/" else: uriPath
    req.uri.scheme = $evhttp_uri_get_scheme(evUri)
    req.uri.query = $evhttp_uri_get_query(evUri)
    req.uri.anchor = $evhttp_uri_get_fragment(evUri)
  # Call the user-defined request handler
  let handler = cast[OnRequest](arg)
  if handler != nil: handler(req)

proc start*(server: var WebServer) =
  ## Start the web server with default no-op request handler.
  assert server.httpServer != nil # ensure server is initialized
  assert evhttp_bind_socket(server.httpServer, "0.0.0.0", server.port.uint16) == 0
  discard event_base_dispatch(server.base) # or event_base_loop(base, 0)

proc start*(server: var WebServer, onRequest: OnRequest,
              startupCallback: StartupCallback = nil) =
  ## Starts the web server event loop.
  assert server.httpServer != nil # ensure server is initialized
  assert evhttp_bind_socket(server.httpServer, "0.0.0.0", server.port.uint16) == 0
  
  # Set the global request handler
  if startupCallback != nil:
    startupCallback() # TODO move to initialRequest?
  evhttp_set_gencb(server.httpServer, initialOnRequest, cast[pointer](onRequest))
  assert event_base_dispatch(server.base) > -1

  # cleanup after event loop ends
  evhttp_free(server.httpServer)
  event_base_free(server.base)

proc send*(req: Request, code: int, body: string, httpHeaders: HttpHeaders = nil) =
  ## Sends an HTTP response.
  if httpHeaders != nil:
    let headers = evhttp_request_get_output_headers(req.raw)
    evhttp_clear_headers(headers)
    for k, v in httpHeaders:
      assert evhttp_add_header(headers, k.cstring, v.cstring) == 0
  let buf = evhttp_request_get_output_buffer(req.raw)
  assert buf != nil # should never be nil
  discard evbuffer_add(buf, body.cstring, body.len.csize_t)
  evhttp_send_reply(req.raw, code.cint, "", buf)

proc send*(req: Request, code: HttpCode, body: string, httpHeaders: HttpHeaders = nil) =
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
  ## This template wraps the body of code that sends chunks.
  ## Once the body of code that sends chunks.
  ## Once the body is done executing it finalizes the chunked response.
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
    # return cached body if already fetched
    return req.body
  # fetch body from evhttp_request
  let buf = evhttp_request_get_input_buffer(req.raw)
  if buf != nil:
    let len = evbuffer_get_length(buf)
    if len > 0:
      var data = newString(len)
      discard evbuffer_copyout(buf, addr(data[0]), len.csize_t)
      req.body = some(data)
  return req.body

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

proc getQuery*(req: var Request): Option[TableRef[string, string]] =
  ## Returns the parsed query parameters from the request URI
  ## as a Table. Lazily initializes on first access. Then caches
  ## them for future accesses.
  if req.uriQuery.isSome:
    return req.uriQuery
  let query = decodeQuery(req.uri.query).toSeq()
  var queryTable = newTable[string, string]()
  if query.len > 0:
    for q in query:
      queryTable[q[0]] = q[1]
  result = some(queryTable)
  req.uriQuery = result

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

proc sendFile*(req: Request, filePath: string, resHeaders: HttpHeaders) =
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
  let ev = event_new(server.base, -1, EV_PERSIST, callback, nil)
  assert ev != nil
  var timeout: event.Timeval
  timeout.tv_sec = 0
  timeout.tv_usec = 30000 # 30ms
  assert event_add(ev, addr(timeout)) == 0

proc addCallback*(server: WebServer, path: string,
        callback: proc(req: ptr evhttp_request, arg: pointer){.cdecl.}) =
  ## Adds a callback for a specific path.
  discard evhttp_set_cb(server.httpServer, path.cstring, callback, nil)
