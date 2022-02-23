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

# import supranim/cache/memcache
# import supranim/events/subscriber

## Import Built-in Service Providers
from supranim/session/cookiejar import CookieServiceProvider
import supranim/services

export Port
export Application, application
export HttpCode, HttpMethod, Request
export send, send404, send500, sendJson, send404Json, send500Json,
       redirect

# Database Environment Configuration
# os.putEnv("DB_HOST", "127.0.0.1")
# os.putEnv("DB_NAME", "vasco")
# os.putEnv("DB_USER", "postgres")
# os.putEnv("DB_PASS", "postgres")


proc onRequest(request: Request): Future[ void ] =
    # Determine the type of the requested method, search for it and
    # return the response if found, otherwise, return a 404 response.
    {.gcsafe.}:
        var reqRoute = request.path.get()
        if request.httpMethod == some(HttpGet):
            if Router.getExists(reqRoute):
                # cookiejar.checkRequestHeaders(request)
                Router.getRoute(reqRoute).runCallable(request)
            request.send404()
            return

        # if request.httpMethod == some(HttpPost):
        #     if router.hasRoute(reqRoute, $request.httpMethod):
        #         router.getRoute(reqRoute).callable(request)
        #         return
        #     request.send404Json()
        #     return

proc start*[A: Application](newApp: var A) =
    ## Procedure for starting your Supranim Application
    ## with current configuration settings and available service providers.
    # Initialize Services via Service Provider
    # cookiejar.enable(enableHashKeys=true, enableEncryption=true)
    run(onRequest, newApp)
