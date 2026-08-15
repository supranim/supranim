#
# Unit tests for supranim/core/router
#
import std/unittest
import std/[httpcore, tables]

import supranim/core/router
import supranim/core/request
import supranim/core/response

proc handler(req: var Request, res: var Response) {.nimcall, gcsafe.} =
  discard

proc mw204(req: var Request, res: var Response): HttpCode {.nimcall.} =
  Http204

proc mw403(req: var Request, res: var Response): HttpCode {.nimcall.} =
  Http403

proc mw302(req: var Request, res: var Response): HttpCode {.nimcall.} =
  Http302

proc newRes(): Response =
  Response(headers: newHttpHeaders())

suite "HttpRouter":
  test "newHttpRouter initializes all method tables":
    let rt = newHttpRouter()
    check rt.httpGet != nil
    check rt.httpPost != nil
    check rt.httpPut != nil
    check rt.httpPatch != nil
    check rt.httpHead != nil
    check rt.httpDelete != nil
    check rt.httpTrace != nil
    check rt.httpOptions != nil
    check rt.httpConnect != nil
    check rt.httpWS != nil
    check rt.httpErrors != nil

  test "static route matches and is scoped to its method":
    var rt = newHttpRouter()
    rt.registerRoute("/static", HttpGet, handler)
    let hit = rt.checkExists("/static", HttpGet)
    check hit.exists
    check hit.route != nil
    check not rt.checkExists("/static", HttpPost).exists
    check not rt.checkExists("/static", HttpPut).exists
    check not rt.checkExists("/nope", HttpGet).exists

  test "dynamic route extracts params":
    var rt = newHttpRouter()
    rt.registerRoute("/users/{id:id}", HttpGet, handler)
    let hit = rt.checkExists("/users/42", HttpGet)
    check hit.exists
    check hit.params["id"] == "42"
    # non-numeric ids do not match the `id` pattern
    check not rt.checkExists("/users/abc", HttpGet).exists

  test "multiple dynamic params are extracted in order":
    var rt = newHttpRouter()
    rt.registerRoute("/users/{id:id}/posts/{slug:slug}", HttpGet, handler)
    let hit = rt.checkExists("/users/7/posts/hello-world", HttpGet)
    check hit.exists
    check hit.params["id"] == "7"
    check hit.params["slug"] == "hello-world"

  test "duplicate route registration does not overwrite":
    var rt = newHttpRouter()
    rt.registerRoute("/static", HttpGet, handler)
    rt.registerRoute("/static", HttpGet, handler)
    check rt.httpGet.len == 1

  test "checkWsExists returns not-exists for an unknown path":
    # NOTE: this must be checked before any ws route is registered — the
    # fallback loop in `checkWsExists` dereferences an uninitialized
    # `regexPath` on ws routes and SIGSEGVs for non-exact paths.
    var rt = newHttpRouter()
    check not rt.checkWsExists("/other").exists

  test "checkWsExists matches a websocket route":
    var rt = newHttpRouter()
    rt.registerRoute(("\\/chat$", "/chat"), HttpGet, handler, isWebSocket = true)
    let hit = rt.checkWsExists("/chat")
    check hit.exists
    check hit.route != nil

  test "resolveMiddleware returns Http204 when there is no middleware":
    var rt = newHttpRouter()
    rt.registerRoute("/plain", HttpGet, handler)
    let route = rt.checkExists("/plain", HttpGet).route
    var req = default(Request)
    var res = newRes()
    check route.resolveMiddleware(req, res) == Http204
    check res.middlewareIndex == 0

  test "resolveMiddleware chains Http204 middlewares in order":
    var rt = newHttpRouter()
    rt.registerRoute("/mw", HttpGet, handler, middlewares = @[mw204, mw204, mw204])
    let route = rt.checkExists("/mw", HttpGet).route
    var req = default(Request)
    var res = newRes()
    check route.resolveMiddleware(req, res) == Http204
    check res.middlewareIndex == 3

  test "resolveMiddleware short-circuits on a non-204 result":
    var rt = newHttpRouter()
    rt.registerRoute("/mw", HttpGet, handler, middlewares = @[mw204, mw403])
    let route = rt.checkExists("/mw", HttpGet).route
    var req = default(Request)
    var res = newRes()
    check route.resolveMiddleware(req, res) == Http403
    # the failing middleware index is not advanced past it
    check res.middlewareIndex == 1

  test "resolveMiddleware stops at a redirect":
    var rt = newHttpRouter()
    rt.registerRoute("/redir", HttpGet, handler, middlewares = @[mw204, mw302, mw403])
    let route = rt.checkExists("/redir", HttpGet).route
    var req = default(Request)
    var res = newRes()
    check route.resolveMiddleware(req, res) == Http302
    check res.middlewareIndex == 1

  test "resolveAfterware returns Http202 when there is no afterware":
    var rt = newHttpRouter()
    rt.registerRoute("/plain", HttpGet, handler)
    let route = rt.checkExists("/plain", HttpGet).route
    var req = default(Request)
    var res = newRes()
    check route.resolveAfterware(req, res) == Http202

  test "resolveAfterware chains Http204 afterwares":
    var rt = newHttpRouter()
    rt.registerRoute("/aw", HttpGet, handler, afterwares = @[mw204, mw204])
    let route = rt.checkExists("/aw", HttpGet).route
    var req = default(Request)
    var res = newRes()
    check route.resolveAfterware(req, res) == Http204
    check res.afterwareIndex == 2

  test "errorHandler registers a 4xx handler and call4xx runs it":
    var rt = newHttpRouter()
    rt.errorHandler(Http404, handler)
    check rt.httpErrors.hasKey("4xx")
    var req = default(Request)
    var res = newRes()
    rt.call4xx(req, res)
