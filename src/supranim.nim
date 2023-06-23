# Supranim is a simple MVC-style web framework for building
# fast web applications, REST API microservices and other cool things.
#
# (c) 2023 Supranim | MIT License
#          Made by Humans from OpenPeep
#          https://supranim.com | https://github.com/supranim

import std/[asyncdispatch, options, times, json]
import pkg/[pkginfo]

import supranim/core/application
import supranim/core/private/[server, router]
import supranim/controller

when requires "emitter":
  import emitter

export json
export application, App, Port
export HttpCode, Http200, Http301, Http302,
        Http403, Http404, Http500, Http503

export HttpMethod, Request, Response

when defined webapp:
  when not defined release:
    # Enable Static Assets Handler for web apps
    import supranim/core/assets
    from std/strutils import startsWith, endsWith

    template serveStaticAssets() =
      # todo handle route static assets via Router
      isStaticFile = true
      let assetsStatus: HttpCode = waitFor Assets.hasFile(reqRoute)
      if assetsStatus == Http200:
        if endsWith(reqRoute, ".css"):
          try:
            let responseBody = res.css(Assets.getFile(reqRoute).src)
            req.sendResponse(res, responseBody)
          except IOError:
            req.send404Response(res)
        elif endsWith(reqRoute, ".js"):
          try:
            let responseBody = res.js(Assets.getFile(reqRoute).src)
            req.sendResponse(res, responseBody)
          except IOError:
            req.send404Response(res)
        elif endsWith(reqRoute, ".svg"):
          try:
            let responseBody = res.svg(Assets.getFile(reqRoute).src)
            req.sendResponse(res, responseBody)
          except IOError:
            req.send404Response(res)
        elif endsWith(reqRoute, ".wasm"):
          try:
            let responseBody = res.response(Assets.getFile(reqRoute).src,
                                    contentType = "application/wasm")
            req.sendResponse(res, responseBody)
          except IOError:
            req.send404Response(res)
        else:
          try:
            let staticAsset = Assets.getFile(reqRoute)
            let responseBody = res.response(staticAsset.src,
                                            contentType = staticAsset.fileType)
            req.sendResponse(res, responseBody)
          except IOError:
            req.send404Response(res)
      else:
        when requires "emitter":
          Event.emit("system.http.assets.404")
        let responseBody = res.send404 getErrorPage(Http404, "404 | Not found")
        req.sendResponse(res, responseBody)
        isStaticFile = false

template handleTrailingSlash() =
  if reqRoute != "/" and reqRoute[^1] == '/':
    reqRoute = reqRoute[0 .. ^2]
    fixTrailingSlash = true

template ensureServiceAvailability() =
  if app.state == false:
    when defined webapp:
      let responseBody: HttpResponse = res.send503 getErrorPage(Http503, "Service Unavailable")
      req.sendResponse(res, responseBody)
    else:
      let responseBody: HttpResponse = res.json503("Service Unavailable")
      req.sendResponse(res, responseBody)

proc onRequest(app: Application, req: var Request, res: var Response): Future[ void ] =
  {.gcsafe.}:
    ensureServiceAvailability()
    var fixTrailingSlash: bool
    var reqRoute = req.getRequestPath()
    when defined webapp:
      when not defined release:
        var isStaticFile: bool # dev mode only
    let verb = req.httpMethod.get()
    let runtime: RuntimeRouteStatus = Router.runtimeExists(verb, reqRoute, req, res)
    case runtime.status:
    of Found:
      when defined webapp:
        if fixTrailingSlash == true: # TODO base-middleware for trailing slashes
          res.redirect(reqRoute, code = HttpCode(301))
        else:
          if runtime.route.isDynamic():
            req.setParams(runtime.params)
          let responseBody: HttpResponse = runtime.route.runCallable(req, res)
          req.sendResponse(res, responseBody)
      else:
        if runtime.route.isDynamic():
          req.setParams(runtime.params)
        let responseBody: HttpResponse = runtime.route.runCallable(req, res)
        req.sendResponse(res, responseBody)
    of BlockedByRedirect:
      # Resolve deferred HTTP redirects declared in current middleware
      when requires "emitter":
        Event.emit("system.http.501")
      res.redirect(res.getDeferredRedirect())
    of BlockedByAbort:
      # Blocked via Middleware by `abort` handler will
      # Emit the `system.http.middleware.redirect` event
      when requires "emitter":
        Event.emit("system.http.middleware.redirect")
      let responseBody: HttpResponse = res.response("", HttpCode 403)
      req.sendResponse(res, responseBody)
    of NotFound:
      case verb
      of HttpGet:
        when defined webapp:
          when not defined release:
            serveStaticAssets()
            if isStaticFile: return
        # handleTrailingSlash()
        when requires "emitter":
          Event.emit("system.http.404")
        when defined webapp:
          let responseBody: HttpResponse = res.send404 getErrorPage(Http404, "404 | Not found")
          req.sendResponse(res, responseBody)
        else:
          let responseBody: HttpResponse = res.json404("Resource not found")
          req.sendResponse(res, responseBody)
      else:
        when requires "emitter":
          Event.emit("system.http.501")
        let responseBody: HttpResponse = res.response("Not Implemented", HttpCode 501)
        req.sendResponse(res, responseBody)

when requires "zmq":
  when defined enableSup:
    # Enables extra functionalities based on ZeroMQ Wrapper
    # This will allow SUP CLI to communicate with your Supranim apps
    import pkg/zmq
    var supThread: Thread[ptr Application]
    proc newZeromq(app: ptr Application) {.thread.} =
      var z = zmq.listen("tcp://" & app.getSupAddress & ":" & app.getSupPort(true), REP)
      while true:
        var req = z.receive()
        if req == "sup.down":
          if app[].state:
            app[].state = false
            z.send "ok"
          else:
            z.send "notok"
        elif req == "sup.up":
          if not app[].state:
            app[].state = true
            z.send "ok"
          else:
            z.send "notok"
      z.close()
  
template start*(app: Application) =
  printBootStatus()
  when requires "zmq":
    when defined enableSup:
      createThread(supThread, newZeromq, app.addr)
  app.state = true # todo
  run(app, onRequest)
