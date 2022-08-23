# Supranim is a simple MVC-style web framework for building
# fast web applications, REST API microservices and other cool things.
#
# (c) 2022 Supranim is released under MIT License
#          Made by Humans from OpenPeep
#          https://supranim.com | https://github.com/supranim

import pkginfo
import std/[asyncdispatch, options, times]

import supranim/core/application
import supranim/core/http/[server, router]
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
                    let cssContent = Assets.getFile(reqRoute)
                    res.css(cssContent.src)
                elif endsWith(reqRoute, ".js"):
                    let jsContent = Assets.getFile(reqRoute)
                    res.js(jsContent.src)
                elif endsWith(reqRoute, ".svg"):
                    let svgContent = Assets.getFile(reqRoute)
                    res.svg(svgContent.src)
                else:
                    let staticAsset = Assets.getFile(reqRoute)
                    res.response(staticAsset.src, contentType = staticAsset.fileType)
            else:
                when requires "emitter":
                    Event.emit("system.http.assets.404")
                res.send404 getErrorPage(Http404, "404 | Not found")

proc onRequest(req: var Request, res: var Response): Future[ void ] =
    {.gcsafe.}:
        var fixTrailingSlash: bool
        var reqRoute = req.path.get()
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

template start*(app: var Application) =
    printBootStatus()
    run(onRequest)
