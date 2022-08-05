# Supranim is a simple MVC-style web framework for building
# fast web applications, REST API microservices and other cool things.
#
# (c) 2022 Supranim is released under MIT License
#          Made by Humans from OpenPeep
#          https://supranim.com | https://github.com/supranim
import pkginfo
when requires "emitter":
    import emitter
import std/[asyncdispatch, options, times]

import supranim/core/http/server
import supranim/[application, router]

when defined webapp:
    import supranim/core/config/assets
    from std/strutils import startsWith, endsWith

import supranim/controller

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
            when requires "emitter":
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
                    # TODO Implement a base middleware to serve static assets
                    serveStaticAssets()
                else:
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
            # When blocked by an `abort` from middleware will
            # Emit the `system.http.middleware.redirect` event
            when requires "emitter":
                Event.emit("system.http.middleware.redirect")
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
                res.response("Not Implemented", HttpCode(501))

proc start*[A: Application](app: A) =
    run(onRequest)
