# Example for creating web application using the low-level Supranim API

import std/[httpcore, tables]
import supranim/core/[router, request, response]
import supranim/network/webserver

proc helloHandler(req: var Request, res: var Response) {.nimcall, gcsafe.} =
  res.setBody("hello world")

proc usersHandler(req: var Request, res: var Response) {.nimcall, gcsafe.} =
  res.setBody("id=" & req.routeParams.getOrDefault("id"))

var appRouter = newHttpRouter()
appRouter.get("/hello", helloHandler)
appRouter.get("/users/{id:id}", usersHandler)

proc onRequest(req: var Request) =
  {.gcsafe.}:
    var res = Response(headers: newHttpHeaders())
    let rc = appRouter.checkExists(req.getUriPath(), req.getHttpMethod())
    if rc.exists:
      req.routeParams = rc.params
      rc.route.callback(req, res)
      if not req.responseSent:
        req.resp(res.getCode(), res.getBody(), res.getHeaders())
    else:
      req.resp(Http404, "not found")

var server = newWebServer()
server.start(onRequest) # default 8080