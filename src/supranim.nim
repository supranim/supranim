# Supranim is a simple MVC-style web framework for building
# fast web applications, REST API microservices and other cool things.
#
# (c) 2022 Supranim is released under MIT License
#          Made by Humans from OpenPeep
#          https://supranim.com | https://github.com/supranim

import emitter
import std/[asyncdispatch, options, times]
import supranim/core/http/server
import supranim/[application, router]
when defined webapp:
    import supranim/core/config/assets

import supranim/support/session
# import supranim/support/schedule

import supranim/controller

from std/os import getAppDir, normalizedPath, getCurrentDir, fileExists
from std/strutils import startsWith, endsWith, parseEnum


export Port
export App, application
export Http200, Http301, Http302, Http403, Http404, Http500, Http503, HttpCode
export HttpMethod, Request, Response
export server.getParams, server.hasParams, server.getCurrentPath

when defined webapp:
    template serveStaticAssets() =
        let assetsStatus: HttpCode = waitFor Assets.hasFile(reqRoute)
        if assetsStatus == Http200:
            if endsWith(reqRoute, ".css"):
                let cssContent = Assets.getFile(reqRoute)
                res.css(cssContent)
            elif endsWith(reqRoute, ".js"):
                let jsContent = Assets.getFile(reqRoute)
                res.js(jsContent)
            else:
                let staticAsset = Assets.getFile(reqRoute)
                res.response(staticAsset)
        else:
            Event.emit("system.http.assets.404")
            res.send404 getErrorPage(Http404, "404 | Not found")

proc onRequest(req: var Request, res: var Response): Future[ void ] =
    {.gcsafe.}:
        var fixTrailingSlash: bool
        var reqRoute = req.path.get()
        let verb = req.httpMethod.get()
        when defined webapp:
            if verb == HttpGet:
                if startsWith(reqRoute, Assets.getPublicPath()):
                    serveStaticAssets() 
                else:
                    if reqRoute != "/" and reqRoute[^1] == '/':
                        reqRoute = reqRoute[0 .. ^2]
                        fixTrailingSlash = true
        let runtime: RuntimeRouteStatus = Router.runtimeExists(verb, reqRoute, req, res)
        case runtime.status:
        of Found:
            when defined webapp:
                if fixTrailingSlash == true:
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
            Event.emit("system.http.501")
            res.redirect(res.getDeferredRedirect())
        of BlockedByAbort:
            # When blocked by an `abort` from middleware will
            # Emit the `system.http.middleware.redirect` event
            Event.emit("system.http.middleware.redirect")
        of NotFound:
            if verb == HttpGet:
                Event.emit("system.http.404")
                if App.getAppType == RESTful:
                    res.send404 getErrorPage(Http404, "404 | Not found")
                else:
                    res.json404("Resource not found")
            else:
                Event.emit("system.http.501")
                res.response("Not Implemented", HttpCode(501))

proc startServer*[A: Application](app: var A) =
    # Session.init()
    # Schedule.init()
    run(onRequest, app)
