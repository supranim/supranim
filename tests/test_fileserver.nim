#
# Unit + integration tests for supranim/core/fileserver hardening:
# traversal guard, ETag/conditional requests, byte ranges, cache headers.
#
# Unit tests use fake `Request`s (headers only, no network). The integration
# suite boots a real powpow server in a child (fork / respawn, same pattern
# as `test_server_integration`) and probes it over HTTP.
#
import std/unittest
import std/[os, httpcore, net, tables, strutils, options, times]
when defined(windows):
  import std/osproc
else:
  import std/posix

import helpers
import supranim/network/webserver
import supranim/core/[request, response, fileserver]

proc fakeReq(headers: openArray[(string, string)] = []): Request =
  var h = newHttpHeaders()
  for (k, v) in headers:
    h.add(k, v)
  Request(headersFetched: true, headersCache: h,
    routeParams: initTable[string, string]())

suite "fileserver helpers (no network)":
  test "isTraversalPath blocks escapes, allows normal paths":
    check isTraversalPath("../secret.txt")
    check isTraversalPath("a/../../secret.txt")
    check isTraversalPath("/../secret.txt")
    check isTraversalPath("sub/../..")
    check not isTraversalPath("assets/app.css")
    check not isTraversalPath("/assets/app.css")
    check not isTraversalPath("a/..b/c")
    check not isTraversalPath("a/b..c")
    check not isTraversalPath("")

  test "mimeFor never raises, handles dotless and empty":
    check mimeFor(".html").contains("html")
    check mimeFor("html").contains("html")
    check mimeFor("") == "application/octet-stream"
    check mimeFor(".") == "application/octet-stream"
    check mimeFor(".nopezzz").len > 0

  test "fileETag is stable and changes with size/mtime":
    let t = fromUnix(1700000000)
    check fileETag(16, t) == fileETag(16, t)
    check fileETag(16, t) != fileETag(17, t)
    check fileETag(16, t) != fileETag(16, fromUnix(1700000001))

  test "httpDate formats an HTTP date":
    check httpDate(fromUnix(0)) == "Thu, 01 Jan 1970 00:00:00 GMT"

  test "notModified matches etag and star only":
    var req = fakeReq({"if-none-match": "W/\"10-abc\""})
    check req.notModified("W/\"10-abc\"")
    var req2 = fakeReq({"if-none-match": "W/\"other\""})
    check not req2.notModified("W/\"10-abc\"")
    var req3 = fakeReq({"if-none-match": "*"})
    check req3.notModified("W/\"10-abc\"")
    var req4 = fakeReq()
    check not req4.notModified("W/\"10-abc\"")

  test "setStaticCacheHeaders adds all four headers":
    var h = newHttpHeaders()
    setStaticCacheHeaders(h, "W/\"1-2\"", "Thu, 01 Jan 1970 00:00:00 GMT")
    check h["ETag"] == "W/\"1-2\""
    check h["Last-Modified"] == "Thu, 01 Jan 1970 00:00:00 GMT"
    check h["Cache-Control"] == "public, max-age=86400"
    check h["Accept-Ranges"] == "bytes"

  test "sendAssets bool overload rejects traversal without sending":
    var req = fakeReq()
    var h = newHttpHeaders()
    check not req.sendAssets("/tmp", "../secret.txt", h)
    check not req.responseSent

  test "stop on a fresh server is a safe no-op":
    var s = newWebServer()
    s.stop()
    s.stop()

#
# Integration: real server serving a temp dir
#
var
  gPort: Port
  gBase: string
  gBasePtr: ptr string

proc staticHandler(req: var Request, res: var Response) =
  var h = newHttpHeaders()
  if req.sendAssets(gBasePtr[], req.getUriPath(), h):
    discard
  else:
    req.resp(Http404, "not found")

proc directHandler(req: var Request, res: var Response) =
  req.sendAssetFile(gBasePtr[] / "direct.txt", newHttpHeaders())

proc onRequestSrv(req: var webserver.Request) {.gcsafe.} =
  {.gcsafe.}:
    var res = Response(headers: newHttpHeaders())
    if req.getUriPath() == "/direct":
      directHandler(req, res)
    else:
      staticHandler(req, res)

proc serverEntry() =
  var server = newWebServer(gPort)
  server.start(onRequestSrv, nil)

proc buildState(port: Port, base: string) =
  gPort = port
  gBase = base
  gBasePtr = addr gBase

when defined(windows):
  var childProc: Process = nil
  if paramCount() >= 3 and paramStr(1) == "--supranim-serve-files":
    buildState(Port(parseInt(paramStr(2))), paramStr(3))
    serverEntry()
    quit(0)
  let srvBase = tempDir("supranim_files_")
  writeFile(srvBase / "hello.txt", "file-content-123")
  writeFile(srvBase / "direct.txt", "direct-body")
  let srvPort = getFreePort()
  buildState(srvPort, srvBase)
  childProc = startProcess(getAppFilename(),
    args = ["--supranim-serve-files", $srvPort.int, srvBase])
  proc cleanup() {.noconv.} =
    if childProc != nil:
      if childProc.running:
        childProc.terminate()
        discard childProc.waitForExit(5000)
      childProc.close()
  addQuitProc(cleanup)
  check waitForTcp(srvPort)
else:
  let srvBase = tempDir("supranim_files_")
  writeFile(srvBase / "hello.txt", "file-content-123")
  writeFile(srvBase / "direct.txt", "direct-body")
  let srvPort = getFreePort()
  buildState(srvPort, srvBase)
  let childPid = fork()
  check childPid >= 0
  if childPid == 0:
    serverEntry()
    quit(0)
  else:
    proc cleanup() {.noconv.} =
      var status: cint
      discard kill(childPid, SIGKILL)
      discard waitpid(childPid, status, 0)
    addQuitProc(cleanup)
  check waitForTcp(srvPort)

proc baseUrl(): string =
  "http://127.0.0.1:" & $gPort

suite "fileserver integration (powpow backend)":
  test "GET serves the file with cache headers":
    let res = httpGet(baseUrl() & "/hello.txt")
    check res.code == Http200
    check res.body == "file-content-123"
    check res.headers["etag"].len > 0
    check res.headers["cache-control"] == "public, max-age=86400"
    check res.headers["accept-ranges"] == "bytes"
    check res.headers["last-modified"].len > 0

  test "If-None-Match yields 304":
    let first = httpGet(baseUrl() & "/hello.txt")
    let etag = first.headers["etag"]
    check etag.len > 0
    let res = httpGetWithHeaders(baseUrl() & "/hello.txt",
      {"If-None-Match": $etag})
    check res.code == Http304

  test "byte range yields 206 with the prefix":
    let res = httpGetWithHeaders(baseUrl() & "/hello.txt",
      {"Range": "bytes=0-3"})
    check res.code == Http206
    check res.body == "file"

  test "traversal is not served":
    check httpGet(baseUrl() & "/../app.nimble").code == Http404
    check httpGet(baseUrl() & "/sub/../../app.nimble").code == Http404

  test "sendAssetFile serves a fixed file":
    let res = httpGet(baseUrl() & "/direct")
    check res.code == Http200
    check res.body == "direct-body"
    check res.headers["etag"].len > 0
