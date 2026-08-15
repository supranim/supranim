#
# Test helpers for the Supranim test suite.
#
# NOTE: this file intentionally does NOT start with `t` so that
# `nimble test` does not pick it up as an entry point.
#
import std/[net, os, httpclient, strutils, times]
export code, body

proc getFreePort*(): Port =
  ## Returns a currently-free TCP port by binding to `Port(0)`,
  ## reading the assigned port and closing the socket.
  var socket = newSocket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
  defer: socket.close()
  socket.bindAddr(Port(0))
  socket.getLocalAddr()[1]

proc waitForTcp*(port: Port, retries = 100, intervalMs = 50): bool =
  ## Polls a TCP connect until the server accepts or `retries` is exhausted.
  for i in 0..<retries:
    var socket: Socket
    try:
      socket = newSocket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
      socket.connect("127.0.0.1", port, timeout = 500)
      socket.close()
      return true
    except CatchableError:
      if socket != nil:
        socket.close()
      sleep(intervalMs)
  false

proc tempDir*(prefix = "supranim_test_"): string =
  ## Creates a unique temporary directory and returns its absolute path.
  result = getTempDir() / prefix & $getCurrentProcessId() & "_" & $(epochTime().int64)
  createDir(result)

proc newClient*(): HttpClient =
  ## A synchronous HTTP client with a generous timeout.
  result = newHttpClient(timeout = 10_000)
  result.headers = newHttpHeaders({"Connection": "close"})

proc httpGet*(url: string): Response =
  ## Performs a synchronous GET and returns the response.
  var client = newClient()
  defer: client.close()
  client.get(url)

proc httpGetRetry*(url: string, attempts = 60, intervalMs = 1000): Response =
  ## Performs a GET, retrying while the server is not yet accepting
  ## connections (connection errors only). A response is returned as soon as
  ## the server answers; HTTP status codes are not retried.
  var lastErr: ref CatchableError
  for i in 0..<attempts:
    try:
      return httpGet(url)
    except CatchableError as e:
      lastErr = e
      sleep(intervalMs)
  raise lastErr

proc httpGetNoRedirect*(url: string): Response =
  ## Performs a GET without following redirects.
  var client = newHttpClient(maxRedirects = 0, timeout = 10_000)
  defer: client.close()
  client.get(url)

proc httpGetWithHeaders*(url: string,
    headers: openArray[(string, string)]): Response =
  ## Performs a GET with custom request headers.
  var client = newClient()
  defer: client.close()
  for (k, v) in headers:
    client.headers[k] = v
  client.get(url)

proc httpPost*(url, body: string, contentType = "application/x-www-form-urlencoded"): Response =
  ## Performs a synchronous POST and returns the response.
  var client = newClient()
  defer: client.close()
  if contentType.len > 0:
    client.headers["Content-Type"] = contentType
  client.post(url, body)

proc httpDelete*(url: string): Response =
  ## Performs a synchronous DELETE and returns the response.
  var client = newClient()
  defer: client.close()
  client.request(url, httpMethod = HttpDelete)
