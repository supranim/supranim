#
# Router hardening tests: error handlers, HEAD fallback, 405, replace/has
#
import std/unittest
import std/[httpcore, tables]

import supranim/core/router
import supranim/core/request
import supranim/core/response

proc handler(req: var Request, res: var Response) {.nimcall, gcsafe.} =
  discard

proc handler2(req: var Request, res: var Response) {.nimcall, gcsafe.} =
  discard

proc newRes(): Response =
  Response(headers: newHttpHeaders())

suite "Router hardening":
  test "errorHandler stores specific + generic fallback":
    var rt = newHttpRouter()
    rt.errorHandler(Http404, handler)
    check rt.httpErrors.hasKey("404")
    check rt.httpErrors.hasKey("4xx")
    check rt.hasErrorHandler(Http404)
    check rt.hasErrorHandler(Http400) # via generic
    check not rt.hasErrorHandler(Http500)

  test "errorHandler 5xx uses 5xx slot":
    var rt = newHttpRouter()
    rt.errorHandler(Http500, handler)
    check rt.httpErrors.hasKey("500")
    check rt.httpErrors.hasKey("5xx")
    check rt.hasErrorHandler(Http500)
    check rt.hasErrorHandler(Http502) # via generic fallback
    check not rt.hasErrorHandler(Http404)

  test "first generic wins, specifics always stored":
    var rt = newHttpRouter()
    rt.errorHandler(Http404, handler)
    rt.errorHandler(Http400, handler2)
    check rt.httpErrors.hasKey("404")
    check rt.httpErrors.hasKey("400")
    check rt.httpErrors.hasKey("4xx")
    # specific keys point to their own handlers
    check rt.httpErrors["404"].callback == handler
    check rt.httpErrors["400"].callback == handler2

  test "call4xx/call5xx are safe no-ops when unregistered":
    var rt = newHttpRouter()
    var req = default(Request)
    var res = newRes()
    # must not raise KeyError
    rt.call4xx(req, res)
    rt.call5xx(req, res)
    check not rt.callError(Http404, req, res)
    check not rt.callError(Http500, req, res)

  test "callError prefers specific over generic":
    var rt = newHttpRouter()
    rt.errorHandler(Http404, handler)
    var req = default(Request)
    var res = newRes()
    check rt.callError(Http404, req, res) # specific
    check rt.callError(Http400, req, res) # via 4xx fallback
    check not rt.callError(Http500, req, res)

  test "hasRoute / replaceRoute / unregisterWsRoute":
    var rt = newHttpRouter()
    check not rt.hasRoute("/a", HttpGet)
    rt.registerRoute("/a", HttpGet, handler)
    check rt.hasRoute("/a", HttpGet)
    check not rt.hasRoute("/a", HttpPost)
    # duplicate ignored
    rt.registerRoute("/a", HttpGet, handler2)
    # replace overwrites
    rt.replaceRoute(("^\\/a$", "/a"), HttpGet, handler2)
    check rt.hasRoute("/a", HttpGet)
    # ws unregister
    rt.registerRoute(("\\/ws$", "/ws"), HttpGet, handler, isWebSocket = true)
    check rt.checkWsExists("/ws").exists
    rt.unregisterWsRoute("/ws")
    check not rt.checkWsExists("/ws").exists
    # unregister unknown is no-op
    rt.unregisterRoute(("", "/missing"), HttpGet)
    rt.unregisterWsRoute("/missing")

  test "HEAD falls back to GET":
    var rt = newHttpRouter()
    rt.registerRoute("/h", HttpGet, handler)
    check rt.checkExists("/h", HttpGet).exists
    let headHit = rt.checkExists("/h", HttpHead)
    check headHit.exists
    # explicit HEAD wins over fallback
    rt.registerRoute("/h2", HttpGet, handler)
    rt.registerRoute("/h2", HttpHead, handler2)
    let h2 = rt.checkExists("/h2", HttpHead)
    check h2.exists
    check h2.route.callback == handler2

  test "allowedMethods and isMethodNotAllowed":
    var rt = newHttpRouter()
    rt.registerRoute("/m", HttpGet, handler)
    rt.registerRoute("/m", HttpPost, handler)
    let allowed = rt.allowedMethods("/m")
    check HttpGet in allowed
    check HttpPost in allowed
    check HttpPut notin allowed
    check rt.isMethodNotAllowed("/m", HttpPut)
    check not rt.isMethodNotAllowed("/m", HttpGet)
    check not rt.isMethodNotAllowed("/missing", HttpGet)
    # HEAD not "not allowed" when GET exists
    check not rt.isMethodNotAllowed("/m", HttpHead)

  test "dynamic 405 detection":
    var rt = newHttpRouter()
    rt.registerRoute("/users/{id:id}", HttpGet, handler)
    check rt.checkExists("/users/42", HttpGet).exists
    check rt.isMethodNotAllowed("/users/42", HttpPost)
    check HttpGet in rt.allowedMethods("/users/42")

  test "resolveMiddleware guards out-of-range index":
    var rt = newHttpRouter()
    proc mw204(req: var Request, res: var Response): HttpCode {.nimcall.} =
      Http204
    rt.registerRoute("/mw", HttpGet, handler, middlewares = @[mw204])
    let route = rt.checkExists("/mw", HttpGet).route
    var req = default(Request)
    var res = newRes()
    res.middlewareIndex = 99
    check route.resolveMiddleware(req, res) == Http204

  test "resolveAfterware guards out-of-range index":
    var rt = newHttpRouter()
    proc aw204(req: var Request, res: var Response): HttpCode {.nimcall.} =
      Http204
    rt.registerRoute("/aw", HttpGet, handler, afterwares = @[aw204])
    let route = rt.checkExists("/aw", HttpGet).route
    var req = default(Request)
    var res = newRes()
    res.afterwareIndex = 99
    check route.resolveAfterware(req, res) == Http204

  test "getMiddlewares/getAfterwares return empty when none":
    var rt = newHttpRouter()
    rt.registerRoute("/plain", HttpGet, handler)
    let route = rt.checkExists("/plain", HttpGet).route
    check route.getMiddlewares().len == 0
    check route.getAfterwares().len == 0
