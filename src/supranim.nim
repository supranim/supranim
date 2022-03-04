# Supranim is a simple Hyper Server and Web Framework developed
# for building safe & fast in-house applications.
#
# (c) 2021 Supranim is released under MIT License
#          by George Lemon <georgelemon@protonmail.com>
#          
#          Website https://supranim.com
#          Github Repository: https://github.com/supranim

from os import getAppDir, normalizedPath

import std/[asyncdispatch, options, times]
import supranim/[application, router, server]
import jsony

# import supranim/cache/memcache
# import supranim/events/subscriber

## Import Built-in Service Providers
from supranim/session/cookiejar import CookieServiceProvider
import supranim/services

export Port
export Application, application
export HttpCode, HttpMethod, Request, Response
export send, send404, send500, json, json404, json500, redirect, redirect302
export jsony

# Database Environment Configuration
# os.putEnv("DB_HOST", "127.0.0.1")
# os.putEnv("DB_NAME", "vasco")
# os.putEnv("DB_USER", "postgres")
# os.putEnv("DB_PASS", "postgres")

proc onRequest(req: Request, res: Response): Future[ void ] =
    # Determine the type of the requested method, search for it and
    # return the response if found, otherwise, return a 404 response.
    {.gcsafe.}:
        let path = req.path.get()
        var reqRoute = path
        if req.httpMethod == some(HttpGet):
            var fixTrailingSlash = false
            if reqRoute[^1] == '/':
                reqRoute = path[0 .. ^2]
                fixTrailingSlash = true
            if Router.getExists(reqRoute):
                if fixTrailingSlash:
                    res.redirect(reqRoute)
                else:
                    Router.getRoute(reqRoute).runCallable(req, res)
                return
            res.send404()
            return

        if req.httpMethod == some(HttpPost):
            if Router.getExists(reqRoute):
                res.json("hello")
                return
            res.json404()
            return

proc start*[A: Application](newApp: var A) =
    ## Procedure for starting your Supranim Application
    ## with current configuration settings and available service providers.
    # Initialize Services via Service Provider
    # cookiejar.enable(enableHashKeys=true, enableEncryption=true)
    run(onRequest, newApp)
