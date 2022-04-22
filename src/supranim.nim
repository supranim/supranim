# Supranim is a simple Hyper Server and Web Framework developed
# for building safe & fast in-house applications.
#
# (c) 2021 Supranim is released under MIT License
#          Developed by Humans from OpenPeep
#          
#          Website https://supranim.com
#          Github Repository: https://github.com/supranim

from os import getAppDir, normalizedPath, getCurrentDir, fileExists

import jsony
import std/[asyncdispatch, options, times]
import supranim/[application, router, server]

from std/strutils import startsWith

export Port
export App, application

export Http200, Http301, Http302, Http403, Http404, Http500, Http503
export HttpMethod, Request, Response
export response, send404, send500, json, json404, json500, redirect, redirect302, view

export server.getParams, server.hasParams, server.getCurrentPath, server.isPage
export jsony

proc expect(httpMethod: Option[HttpMethod], expectMethod: HttpMethod): bool =
    ## Determine if given HttpMethod is as expected
    result = httpMethod == some(expectMethod)

proc onRequest(req: var Request, res: var Response, app: Application): Future[ void ] =
    ## Procedure called during runtime. Determine type of the current request
    ## find a route and return the callable, otherwise prompt a 404 Response.
    {.gcsafe.}:
    # This procedure covers all methods from HttpMethod. Note that
    # we are going to use only if statements in order to determine the
    # method type of current request because, for some reasons,
    # simple if statements are faster than if/elif blocks.
        var reqRoute = req.path.get()
        
        # Handle HttpGET requests
        if expect(req.httpMethod, HttpGet):
            if app.hasAssets() and startsWith(reqRoute, app.instance(Assets).getPublicPath()):
                if app.instance(Assets).hasFile(reqRoute):
                    res.response(app.instance(Assets).getFile(reqRoute))
                else:
                    res.send404()
                return

            let metaRouteTuple: RuntimeRoutePattern = Router.existsRuntime(HttpGet, reqRoute)
            if metaRouteTuple.status == true:
                let isDynamicRoute = metaRouteTuple.isDynamic
                var routeInstance: Route = Router.getRoute(metaRouteTuple.key, isDynamicRoute)
                if isDynamicRoute:
                    req.setParams(metaRouteTuple.params)
                routeInstance.runCallable(req, res)
                return
            res.send404()
            return

        # Handle HttpPost requests
        if expect(req.httpMethod, HttpPost):
            discard

        # Handle HttpPut requests
        if expect(req.httpMethod, HttpPut):
            discard

        # Handle HttpOptions requests
        if expect(req.httpMethod, HttpOptions):
            discard
        
        # Handle HttpHead requests
        if expect(req.httpMethod, HttpHead):
            discard

        # Handle HttpDelete requests
        if expect(req.httpMethod, HttpDelete):
            discard

        # Handle HttpTrace requests
        if expect(req.httpMethod, HttpTrace):
            discard

        # Handle HttpConnect requests
        if expect(req.httpMethod, HttpConnect):
            discard

        # Handle HttpPatch requests
        if expect(req.httpMethod, HttpPatch):
            discard

proc start*[A: Application](app: var A) =
    run(onRequest, app)
