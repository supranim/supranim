# Supranim is a simple MVC-style web framework for building
# fast web applications, REST API microservices and other cool things.
#
# (c) 2021 Supranim is released under MIT License
#          George Lemon | Made by Humans from OpenPeep
#          https://supranim.com   |    https://github.com/supranim

import std/[asyncdispatch, options, times]
import supranim/[application, router, server]
import supranim/private/config/assets

# when defined(webapp):
#     import emitter

from std/os import getAppDir, normalizedPath, getCurrentDir, fileExists
from std/strutils import startsWith, endsWith
from ./supranim/core/http/response import json_error, response, css, send404, redirect

export Port
export App, application
export Http200, Http301, Http302, Http403, Http404, Http500, Http503, HttpCode
export HttpMethod, Request, Response
export server.getParams, server.hasParams, server.getCurrentPath, server.isPage

proc expect(httpMethod: Option[HttpMethod], expectMethod: HttpMethod): bool =
    ## Determine if given HttpMethod is as expected
    result = httpMethod == some(expectMethod)

proc handleHttpRouteRequest(verb: HttpMethod, req: var Request, res: var Response,
                                reqRoute: string, hasTrailingSlash = false) =
    let runtime: RuntimeRoutePattern = Router.existsRuntime(verb, reqRoute, req, res)
    case runtime.status:
    of Found:
        if verb == HttpGet:
            if hasTrailingSlash:
                res.redirect(reqRoute, code = HttpCode(301)) # handle trailing slashes for GET requests
                return
        if runtime.route.isDynamic():
            req.setParams(runtime.params)
        runtime.route.runCallable(req, res)
    of BlockedByRedirect:
        # Resolve deferred HTTP redirects declared in current middleware
        # TODO find better way to handle redirects
        res.redirect(res.getRedirect())
    of BlockedByAbort:
        # Blocked by an `abort` from a middleware.
        # TODO implement system logs
        discard
    of NotFound:
        case verb:
        of HttpGet:
            if App.getAppType == RESTful:
                res.send404 getErrorPage(Http404, "404 | Not found")
            else:
                res.send404 getErrorPage(Http404, "404 | Not found")
        else: res.response("Not Implemented", HttpCode(501))

template handleStaticAssetsDev() =
    if Assets.exists() and startsWith(reqRoute, Assets.getPublicPath()):
        let assetsStatus: HttpCode = waitFor Assets.hasFile(reqRoute)
        if assetsStatus == Http200:
            if endsWith(reqRoute, ".css"):
                res.css(Assets.getFile(reqRoute))
            else:
                res.response(Assets.getFile(reqRoute))
        else:
            res.send404 getErrorPage(Http404, "404 | Not found")
        return

proc onRequest(req: var Request, res: var Response, app: Application): Future[ void ] =
    ## Procedure called during runtime. Determine type of the current request
    ## find a route and return the callable, otherwise prompt a 404 Response.
    {.gcsafe.}:
    # This procedure covers all methods from HttpMethod. Note that
    # we are going to use only if statements in order to determine the
    # method type of current request because, for some reasons,
    # simple if statements are faster than if/elif blocks.
        var hasTrailingSlash: bool
        var reqRoute = req.path.get()
        if reqRoute != "/":
            if reqRoute[^1] == '/':
                reqRoute = reqRoute[0 .. ^2]
                hasTrailingSlash = true
        if expect(req.httpMethod, HttpGet):
            # Handle HttpGET requests
            handleStaticAssetsDev()
            handleHttpRouteRequest(HttpGet, req, res, reqRoute, hasTrailingSlash)
            return # block code execution

        if expect(req.httpMethod, HttpPost):
            # Handle HttpPost requests
            handleHttpRouteRequest(HttpPost, req, res, reqRoute)
            return # block code execution

        if expect(req.httpMethod, HttpPut):
            # Handle HttpPut requests
            handleHttpRouteRequest(HttpPut, req, res, reqRoute)
            return # block code execution

        if expect(req.httpMethod, HttpOptions):
            # Handle HttpOptions requests
            handleHttpRouteRequest(HttpOptions, req, res, reqRoute)
            return # block code execution

        if expect(req.httpMethod, HttpHead):
            # Handle HttpHead requests
            handleHttpRouteRequest(HttpHead, req, res, reqRoute)
            return # block code execution
        
        if expect(req.httpMethod, HttpDelete):
            # Handle HttpDelete requests
            handleHttpRouteRequest(HttpDelete, req, res, reqRoute)
            return # block code execution

        if expect(req.httpMethod, HttpTrace):
            # Handle HttpTrace requests
            handleHttpRouteRequest(HttpTrace, req, res, reqRoute)
            return # block code execution

        if expect(req.httpMethod, HttpConnect):
            # Handle HttpConnect requests
            handleHttpRouteRequest(HttpConnect, req, res, reqRoute)
            return # block code execution

        if expect(req.httpMethod, HttpPatch):
            # Handle HttpPatch requests
            handleHttpRouteRequest(HttpPatch, req, res, reqRoute)
            return # block code execution

proc startServer*[A: Application](app: var A) =
    run(onRequest, app)
