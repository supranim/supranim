# Supranim is a simple MVC web framework
# for building web apps & microservices in Nim.
#
# (c) 2024 MIT License | Made by Humans from OpenPeeps
# https://supranim.com | https://github.com/supranim

import std/[options, asyncdispatch, asynchttpserver, httpcore, streams,
    osproc, os, strutils, sequtils, posix_utils, uri]

import ./supranim/application
import ./supranim/service/[dev, events]
import ./supranim/core/[http, utils, docs]

from std/net import Port, `$`

export application

#
# Httpbeast Wrapper
#
template run*(app: Application) =
  proc onRequest(req: http.Request): Future[void] =
    {.gcsafe.}:
      var reqPath = req.path.get()
      var req = newRequest(req, parseUri(reqPath))
      reqPath = req.getUriPath
      var trailingSlash, isStaticFile: bool
      if reqPath != "/" and reqPath[^1] == '/':
        reqPath = reqPath[0..^2]
        trailingSlash = true
      let runtimeCheck = Router.checkExists(reqPath, req.root.httpMethod.get())
      var res = Response(headers: newHttpHeaders())
      case runtimeCheck.exists
      of true:
        req.initRequestHeaders()
        if trailingSlash:
          res.addHeader("Location", reqPath)
          req.root.resp(code = HttpCode(301), "", res.getHeaders())
        let middlewareStatus: HttpCode = runtimeCheck.route.resolveMiddleware(req, res)
        case middlewareStatus
        of Http200:
          discard runtimeCheck.route.callback(req, res)
          req.root.resp(res.getCode(), res.getBody(), res.getHeaders())
        of Http301, Http302, Http303:
          req.root.resp(middlewareStatus, "", res.getHeaders())
        else:
          req.root.resp(Http403, getDefault(Http403), $getDefaultContentType())
      of false:
        when defined webApp:
          when not defined release:
            # dev.checkDevSession()
            # handleStaticAssetsDevMode()
            if isStaticFile: return
        events.emit("errors.404")
        Router.call4xx(req, res)
        req.root.resp(Http404, res.getBody(), res.getHeaders())
      freemem(req)
      freemem(res)
  
  proc startup() =
    initRouter()
    initRouterErrorHandlers() # register 4xx/5xx error handlers

  let settings = initSettings(
    Port(app.config("server", "port").getInt),
    app.config("server", "address").getString,
    app.config("server", "threads").getInt,
    startup
  )
  echo("Starting ", settings.numThreads, " threads")
  echo("Running at http://", settings.bindAddr, ":", $(settings.port))
  http.runServer(onRequest, settings)