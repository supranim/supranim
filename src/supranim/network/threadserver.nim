#
# Supranim is a high-performance web framework for building
# web applications and microservices in Nim
# 
#   (c) 2026 LGPL-v3-or-later License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#

## This module implements a simple threaded HTTP server using Nim's standard library
## The server listens for incoming connections, spawns a new thread for each client,
## and handles HTTP requests separately for each client.
## 
## The threaded server can be useful for handling multiple clients concurrently for
## CPU-bound tasks, but it may not be the best choice for high-concurrency scenarios due to the overhead
## of thread creation and context switching. For high-concurrency scenarios, consider using
## the default Supranim server built on top of Libevent.
import std/[nativesockets, posix, strutils,
        times, net, options, httpcore, parseutils]

import pkg/malebolgia

type
  Data = object
    id: uint
      # A fd for the client connection, as an unsigned int
    ip: string
      # The client's IP address, as a string.
  
  Request* = object
    data: Data
      # The selector for the request, as an unsigned int.
    client*: SocketHandle
      # The client's socket handle, as an unsigned int.

#
# Http parser
#
proc parseHttpMethod(data: string, start: int): Option[HttpMethod] =
  ## Parses the data to find the request HttpMethod.

  # HTTP methods are case sensitive.
  # (RFC7230 3.1.1. "The request method is case-sensitive.")
  case data[start]
  of 'G':
    if data[start+1] == 'E' and data[start+2] == 'T':
      return some(HttpGet)
  of 'H':
    if data[start+1] == 'E' and data[start+2] == 'A' and data[start+3] == 'D':
      return some(HttpHead)
  of 'P':
    if data[start+1] == 'O' and data[start+2] == 'S' and data[start+3] == 'T':
      return some(HttpPost)
    if data[start+1] == 'U' and data[start+2] == 'T':
      return some(HttpPut)
    if data[start+1] == 'A' and data[start+2] == 'T' and
       data[start+3] == 'C' and data[start+4] == 'H':
      return some(HttpPatch)
  of 'D':
    if data[start+1] == 'E' and data[start+2] == 'L' and
       data[start+3] == 'E' and data[start+4] == 'T' and
       data[start+5] == 'E':
      return some(HttpDelete)
  of 'O':
    if data[start+1] == 'P' and data[start+2] == 'T' and
       data[start+3] == 'I' and data[start+4] == 'O' and
       data[start+5] == 'N' and data[start+6] == 'S':
      return some(HttpOptions)
  else: discard

  return none(HttpMethod)

proc methodNeedsBody(headers: string): bool =
  let m = parseHttpMethod(headers, start = 0)
  m.isSome() and m.get() in {HttpPost, HttpPut, HttpConnect, HttpPatch}

template fastHeadersCheck(data: ptr Data): untyped =
  (let res = data.data[^1] == '\l' and data.data[^2] == '\c' and
             data.data[^3] == '\l' and data.data[^4] == '\c';
   if res: data.headersFinishPos = data.data.len;
   res)

proc getHeaderValue(headers: string, name: string): string =
  for line in headers.splitLines():
    let l = line.strip()
    if l.len == 0: break
    let lower = l.toLowerAscii()
    if lower.startsWith(name & ":"):
      return l[(name.len + 1) .. ^1].strip()
#
# Server API
#
const DefaultPort = Port(8080)

proc nowHttpDate: string =
   now().utc().format("ddd, dd MMM yyyy HH:mm:ss 'GMT'")

proc sendAll(fd: SocketHandle, s: string): bool =
  var off = 0
  while off < s.len:
    let n = posix.send(fd, cast[pointer](unsafeAddr s[off]), s.len - off, 0)
    if n < 0:
      if posix.errno == posix.EINTR:
        continue
      return false
    if n == 0:
      return false
    inc(off, n)
  true

proc readOneRequest(fd: SocketHandle, pending: var string): (bool, bool, string) =
  ## returns (ok, clientRequestedClose, headersOnly)
  while true:
    let p = pending.find("\r\n\r\n")
    if p >= 0:
      let endPos = p + 4
      let headers = pending[0 ..< endPos]
      if endPos < pending.len:
        pending = pending[endPos .. ^1]
      else:
        pending.setLen(0)
      let lower = headers.toLowerAscii()
      return (true, lower.contains("connection: close"), headers)

    var buf: array[4096, char]
    let n = posix.recv(fd, unsafeAddr buf[0], buf.len, 0)
    if n <= 0:
      return (false, false, "")
    let oldLen = pending.len
    pending.setLen(oldLen + n)
    for i in 0 ..< n:
      pending[oldLen + i] = buf[i]

proc drainRequestBody(fd: SocketHandle, pending: var string, headers: string): bool =
  let clv = getHeaderValue(headers, "content-length")
  if clv.len == 0:
    return true

  var contentLen: int
  try:
    contentLen = parseInt(clv)
  except:
    return false

  if contentLen <= 0:
    return true

  # consume buffered bytes first
  if pending.len >= contentLen:
    if pending.len == contentLen:
      pending.setLen(0)
    else:
      pending = pending[contentLen .. ^1]
    return true
  else:
    dec(contentLen, pending.len)
    pending.setLen(0)

  var buf: array[4096, char]
  while contentLen > 0:
    let want = if contentLen < buf.len: contentLen else: buf.len
    let n = posix.recv(fd, unsafeAddr buf[0], want, 0)
    if n <= 0:
      return false
    dec(contentLen, n)
  true

proc buildResponse(statusCodeAndMsg: string, body: string,
                   extraHeaders: string = "", connClose = false): string =
  result.add("HTTP/1.1 " & statusCodeAndMsg & "\r\n")
  result.add("Content-Length: " & $body.len & "\r\n")
  result.add("Server: Supranim\r\n")
  result.add("Date: " & nowHttpDate() & "\r\n")
  if extraHeaders.len > 0:
    result.add(extraHeaders)
  if connClose:
    result.add("Connection: close\r\n")
  else:
    result.add("Connection: keep-alive\r\n")
  result.add("\r\n")
  result.add(body)

proc handleClient(fd: SocketHandle) {.thread.} =
  var pending = newString(0)
  try:
    while true:
      let (ok, clientRequestedClose, headers) = readOneRequest(fd, pending)
      if not ok:
        break

      if methodNeedsBody(headers):
        if not drainRequestBody(fd, pending, headers):
          break

      let body = "Hello from threaded Nim server!\n"
      let resp = buildResponse("200 OK", body, "", clientRequestedClose)
      if not sendAll(fd, resp):
        break

      if clientRequestedClose:
        break
  except:
    discard
  finally:
    discard posix.close(cint(fd))

proc serveThreaded(port: Port = DefaultPort) =
  var server = newSocket()
  server.setSockOpt(OptReuseAddr, true)
  server.setSockOpt(OptNoDelay, true)
  server.bindAddr(port)
  server.listen(128)
  echo "Threaded server listening on port ", port

  var m = createMaster()
  while true:
    var client: Socket
    server.accept(client)

    # duplicate the underlying fd so the accept-side Socket can be closed/reused safely
    let rawFd = client.getFd()
    let dupFd = posix.dup(cint(rawFd))
    client.close()            # allow Socket finalizer / reuse without invalidating worker fd
    if dupFd >= 0:
      m.spawn handleClient(SocketHandle(dupFd))

when isMainModule:
  serveThreaded()