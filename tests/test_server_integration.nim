#
# Integration tests for the Supranim HTTP server (powpow backend).
#
# A real powpow WebServer is started in a forked child process and probed
# over HTTP using std/httpclient. Fork is used instead of threads because
# the powpow event loop is not `gcsafe`-annotated.
#
import std/unittest
import std/[os, httpcore, net, posix, tables, strutils, options]

import pkg/powpow as pw

import helpers
import supranim/network/webserver
import supranim/core/[router, request, response]

var
  gPort: Port
  gRouter: ptr HttpRouterInstance
  gFilePathStore: string
  gFilePath: ptr string

#
# Route handlers
#
proc helloHandler(req: var Request, res: var Response) {.nimcall, gcsafe.} =
  res.setBody("hello world")

proc usersHandler(req: var Request, res: var Response) {.nimcall, gcsafe.} =
  res.setBody("id=" & req.routeParams.getOrDefault("id"))

proc queryHandler(req: var Request, res: var Response) {.nimcall, gcsafe.} =
  let q = req.getQuery()
  res.setBody("x=" & q.getOrDefault("x") & ";y=" & q.getOrDefault("y"))

proc bodyHandler(req: var Request, res: var Response) {.nimcall, gcsafe.} =
  res.setBody("body=" & req.getBody().get(""))

proc jsonHandler(req: var Request, res: var Response) {.nimcall, gcsafe.} =
  res.setCode(Http200)
  res.addHeader("Content-Type", "application/json")
  res.setBody("""{"ok":true}""")

proc headerHandler(req: var Request, res: var Response) {.nimcall, gcsafe.} =
  res.setBody("h=" & req.getHeader("x-custom").get(""))

proc cookieHandler(req: var Request, res: var Response) {.nimcall, gcsafe.} =
  var cookie = ""
  if req.hasCookies:
    cookie = req.getCookies().get("")
  res.setBody("cookie=" & cookie)

proc fileHandler(req: var Request, res: var Response) {.nimcall, gcsafe.} =
  req.sendFile(gFilePath[], newHttpHeaders())

#
# Middleware
#
proc mw403(req: var Request, res: var Response): HttpCode {.nimcall.} =
  Http403

proc mw302(req: var Request, res: var Response): HttpCode {.nimcall.} =
  res.addHeader("Location", "/hello")
  Http302

#
# Low-level callback (bypasses the router)
#
proc rawCb(req: pointer, arg: pointer) {.cdecl, gcsafe.} =
  let res = cast[pw.HttpResponse](arg)
  res.status(Http200).send("raw callback")

#
# Server entry point (runs in the forked child)
#
proc onRequest(req: var webserver.Request) {.gcsafe.} =
  {.gcsafe.}:
    var res = Response(headers: newHttpHeaders())
    let path = req.getUriPath()
    let httpMethod = req.getHttpMethod()
    let rc = gRouter[].checkExists(path, httpMethod)
    if rc.exists:
      req.routeParams = rc.params
      let middlewareStatus = rc.route.resolveMiddleware(req, res)
      case middlewareStatus
      of Http301, Http302, Http303:
        req.resp(middlewareStatus, "", res.getHeaders())
      of Http204:
        rc.route.callback(req, res)
        discard rc.route.resolveAfterware(req, res)
        if not req.responseSent:
          if res.getBody().len > 0:
            req.resp(res.getCode, res.getBody(), res.getHeaders())
          else:
            req.resp(res.getCode, "")
      else:
        req.resp(middlewareStatus, "")
    else:
      req.resp(Http404, "not found")

proc serverEntry() =
  var server = newWebServer(gPort)
  server.addCallback("/raw", rawCb)
  server.start(onRequest, nil)

#
# Setup: build the router, write a temp file, fork the server child
#
var rt = newHttpRouter()
rt.registerRoute("/hello", HttpGet, helloHandler)
rt.registerRoute("/users/{id:id}", HttpGet, usersHandler)
rt.registerRoute("/echo-query", HttpGet, queryHandler)
rt.registerRoute("/echo-body", HttpPost, bodyHandler)
rt.registerRoute("/json", HttpGet, jsonHandler)
rt.registerRoute("/echo-header", HttpGet, headerHandler)
rt.registerRoute("/cookie", HttpGet, cookieHandler)
rt.registerRoute("/file", HttpGet, fileHandler)
rt.registerRoute("/protected", HttpGet, helloHandler, middlewares = @[mw403])
rt.registerRoute("/redirect", HttpGet, helloHandler, middlewares = @[mw302])

gRouter = cast[ptr HttpRouterInstance](addr rt)
gFilePathStore = tempDir("supranim_int_file_") / "asset.txt"
writeFile(gFilePathStore, "file-content-123")
gFilePath = addr gFilePathStore
gPort = getFreePort()

let childPid = fork()
check childPid >= 0
if childPid == 0:
  serverEntry()
  quit(0)
else:
  proc cleanup() {.noconv.} =
    var status: cint
    removeFile(gFilePathStore)
    discard kill(childPid, SIGKILL)
    discard waitpid(childPid, status, 0)
  addQuitProc(cleanup)

check waitForTcp(gPort)

proc baseUrl(): string =
  "http://127.0.0.1:" & $gPort

suite "WebServer integration (powpow backend)":
  test "GET a static route returns its body":
    let res = httpGet(baseUrl() & "/hello")
    check res.code == Http200
    check res.body == "hello world"

  test "dynamic route extracts params":
    check httpGet(baseUrl() & "/users/42").body == "id=42"
    check httpGet(baseUrl() & "/users/999").body == "id=999"

  test "non-matching dynamic route returns 404":
    check httpGet(baseUrl() & "/users/abc").code == Http404

  test "unknown route returns 404":
    check httpGet(baseUrl() & "/missing").code == Http404

  test "wrong http method returns 404":
    check httpPost(baseUrl() & "/hello", "").code == Http404

  test "query parameters are parsed":
    check httpGet(baseUrl() & "/echo-query?x=1&y=2").body == "x=1;y=2"
    check httpGet(baseUrl() & "/echo-query").body == "x=;y="

  test "POST body is delivered to the handler":
    check httpPost(baseUrl() & "/echo-body", "a=1&b=2").body == "body=a=1&b=2"

  test "JSON response sets the content type":
    let res = httpGet(baseUrl() & "/json")
    check res.code == Http200
    check res.body == """{"ok":true}"""
    check res.headers["content-type"] == "application/json"

  test "middleware can deny a request with 403":
    check httpGet(baseUrl() & "/protected").code == Http403

  test "middleware can redirect":
    let res = httpGetNoRedirect(baseUrl() & "/redirect")
    check res.code == Http302
    check res.headers["location"] == "/hello"

  test "request headers are accessible":
    check httpGetWithHeaders(baseUrl() & "/echo-header",
        {"X-Custom": "val123"}).body == "h=val123"

  test "cookies are parsed from the request":
    check httpGetWithHeaders(baseUrl() & "/cookie",
        {"Cookie": "ssid=abc123"}).body == "cookie=ssid=abc123"

  test "low-level callbacks bypass the router":
    check httpGet(baseUrl() & "/raw").body == "raw callback"

  test "sendFile serves a file":
    let res = httpGet(baseUrl() & "/file")
    check res.code == Http200
    check res.body == "file-content-123"
