# Supranim is a simple Hyper Server and Web Framework developed
# for building safe & fast in-house applications.
#
# (c) 2021 Supranim is released under MIT License
#          by George Lemon <georgelemon@protonmail.com>
#          
#          Website https://supranim.com
#          Github Repository: https://github.com/supranim

from os import getAppDir, normalizedPath, getCurrentDir, fileExists

import jsony
import std/[asyncdispatch, options, times]
import supranim/[application, router, server]
import supranim/services
import supranim/http/assets

export Port
export App, application
export HttpCode, HttpMethod, Request, Response
export response, send404, send500, json, json404, json500, redirect, redirect302, view
export server.getParams

export jsony

proc onRequest(req: var Request, res: Response): Future[ void ] =
    # Determine the type of the requested method, search for it and
    # return the response if found, otherwise, return a 404 response.
    {.gcsafe.}:
        let path = req.path.get()
        var reqRoute = path
        if req.httpMethod == some(HttpGet):
            let metaRouteTuple: tuple[status: bool, key: string, isDynamic: bool] = Router.existsRuntime(HttpGet, reqRoute)
            if metaRouteTuple.status == true:
                let isDynamicRoute = metaRouteTuple.isDynamic
                var routeInstance: Route = Router.getRoute(metaRouteTuple.key, isDynamicRoute)
                if isDynamicRoute:
                    req.setParams(routeInstance.getRouteParams())
                routeInstance.runCallable(req, res)
                return
            res.send404()
            return

        # if req.httpMethod == some(HttpPost):
        #     if Router.getExists(reqRoute):
        #         res.json("hello")
        #         return
        #     res.json404()
        #     return

proc start*[A: Application](app: var A) =
    run(onRequest, app)