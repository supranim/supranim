# Supranim is a simple MVC-style web framework for building
# fast web applications, REST API microservices and other cool things.
#
# (c) 2023 Supranim | MIT License
#          Made by Humans from OpenPeep
#          https://supranim.com | https://github.com/supranim

import pkg/pkginfo
import std/[asyncdispatch, options, times]

import supranim/core/application
import supranim/core/private/[server, router, websockets]
import supranim/controller

when requires "emitter":
  import emitter

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
      let assetsStatus: HttpCode = waitFor Assets.hasFile(reqRoute)
      if assetsStatus == Http200:
        if endsWith(reqRoute, ".css"):
          try:
            let cssContent = Assets.getFile(reqRoute)
            res.css(cssContent.src)
          except IOError:
            res.send404()
        elif endsWith(reqRoute, ".js"):
          try:
            let jsContent = Assets.getFile(reqRoute)
            res.js(jsContent.src)
          except IOError:
            res.send404()
        elif endsWith(reqRoute, ".svg"):
          try:
            let svgContent = Assets.getFile(reqRoute)
            res.svg(svgContent.src)
          except IOError:
            res.send404()
        elif endsWith(reqRoute, ".wasm"):
          res.response(Assets.getFile(reqRoute).src, contentType = "application/wasm")
        else:
          try:
            let staticAsset = Assets.getFile(reqRoute)
            res.response(staticAsset.src, contentType = staticAsset.fileType)
          except IOError:
            res.send404()
      else:
        when requires "emitter":
          Event.emit("system.http.assets.404")
        res.send404 getErrorPage(Http404, "404 | Not found")

template ensureServiceAvailability() =
  if app.state == false:
    when defined webapp:
      res.send503 getErrorPage(Http503, "Service Unavailable")
    else:
      res.json503("Service Unavailable")

proc onRequest(app: Application, req: var Request, res: var Response): Future[ void ] =
  {.gcsafe.}:
    ensureServiceAvailability()
    var fixTrailingSlash: bool
    var reqRoute = req.getRequestPath()
    let verb = req.httpMethod.get()
    if verb == HttpGet:
      when defined webapp:
        when not defined release:
          if startsWith(reqRoute, Assets.getPublicPath()):
            # TODO Implement a base middleware to serve static assets
            serveStaticAssets()
            return
      if reqRoute != "/" and reqRoute[^1] == '/':
        # TODO implement a base middleware to
        # handle redirects for trailing slashes on GET requests
        reqRoute = reqRoute[0 .. ^2]
        fixTrailingSlash = true
    let runtime: RuntimeRouteStatus = Router.runtimeExists(verb, reqRoute, req, res)
    case runtime.status:
    of Found:
      when defined webapp:
        if fixTrailingSlash == true: # TODO base-middleware for trailing slashes
          res.redirect(reqRoute, code = HttpCode(301))
        else:
          if runtime.route.isDynamic():
            req.setParams(runtime.params)
          runtime.route.runCallable(req, res)
      else:
        if runtime.route.isDynamic():
          req.setParams(runtime.params)
        runtime.route.runCallable(req, res)
    of BlockedByRedirect:
      # Resolve deferred HTTP redirects declared in current middleware
      when requires "emitter":
        Event.emit("system.http.501")
      res.redirect(res.getDeferredRedirect())
    of BlockedByAbort:
      # Blocked by an middleware `abort` will
      # Emit the `system.http.middleware.redirect` event
      when requires "emitter":
        Event.emit("system.http.middleware.redirect")
      res.response("", HttpCode 403)
    of NotFound:
      if verb == HttpGet:
        when defined webapp:
          res.send404 getErrorPage(Http404, "404 | Not found")
        else:
          res.json404("Resource not found")
        when requires "emitter":
          Event.emit("system.http.404")
      else:
        when requires "emitter":
          Event.emit("system.http.501")
        res.response("Not Implemented", HttpCode 501)

when requires "zmq":
  # Check if current application requires ZeroMQ
  # https://github.com/nim-lang/nim-zmq
  # https://nim-lang.github.io/nim-zmq/zmq.html
  when defined enableSup:
    # Enables extra functionalities based on ZeroMQ Wrapper
    # This will allow SUP CLI to communicate with your Supranim apps
    import pkg/zmq
    var supThread: Thread[ptr Application]
    proc newZeromq(app: ptr Application) {.thread.} =
      var z = zmq.listen("tcp://127.0.0.1:5555", REP)
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
