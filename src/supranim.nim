# Supranim is a simple MVC-style web framework for building
# fast web applications, REST API microservices and other cool things.
#
# (c) 2021 Supranim is released under MIT License
#          George Lemon | Made by Humans from OpenPeep
#          https://supranim.com   |    https://github.com/supranim

from os import getAppDir, normalizedPath, getCurrentDir, fileExists

import jsony
import std/[asyncdispatch, options, times]
import supranim/[application, router, server]

from std/strutils import startsWith

export Port
export App, application

export Http200, Http301, Http302, Http403, Http404, Http500, Http503, HttpCode
export HttpMethod, Request, Response
export response, send404, send500, json, json404, json500, json_error, redirect, redirect302, view

export server.getParams, server.hasParams, server.getCurrentPath, server.isPage
export jsony

proc expect(httpMethod: Option[HttpMethod], expectMethod: HttpMethod): bool =
    ## Determine if given HttpMethod is as expected
    result = httpMethod == some(expectMethod)

proc default404Response(res: var Response) =
    ## A default ``404 Response`` based on your preferences
    ## from current App instance
    ## TODO Use `App` singleton to retrieve custom response errors
    res.json_error("Invalid endpoint", Http404)

template handleHttpRouteRequest(verb: HttpMethod, req: Request, res: Response, reqRoute: string) =
    let runtime: RuntimeRoutePattern = Router.existsRuntime(verb, reqRoute, req, res)
    if runtime.status == true:
        if runtime.route.isDynamic():
            req.setParams(runtime.params)
        runtime.route.runCallable(req, res)
    else: res.default404Response()

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
                    res.default404Response()
                return
            handleHttpRouteRequest(HttpGet, req, res, reqRoute)
            return

        # Handle HttpPost requests
        if expect(req.httpMethod, HttpPost):
            handleHttpRouteRequest(HttpPost, req, res, reqRoute)
            return

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
