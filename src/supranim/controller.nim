# Supranim is a simple MVC-style web framework for building
# fast web applications, REST API microservices and other cool things.
#
# (c) 2022 Supranim is released under MIT License
#          Made by Humans from OpenPeep
#          https://supranim.com | https://github.com/supranim

import jsony
import std/[options, sequtils]

from std/uri import decodeQuery
from ./support/str import unquote
from ./core/http/server import Request, requestBody,
                                hasHeaders, hasHeader, getHeaders, getHeader,
                                path, getCurrentPath, getVerb, HttpCode,
                                getParams, hasParams, path

export jsony
export Request, hasHeaders, hasHeader, getHeaders, 
       getHeader, path, getCurrentPath, HttpCode,
       getParams, hasParams, path

#
# Request - Higher-level
#

method getBody*(req: Request): string =
    ## Retrieve the body of given `Request`
    result = req.requestBody.get()

method getFields*(req: Request): seq[(string, string)] =
    ## Parse a body from given Reuqest and return as paris (field, value)
    ## This is useful for `POST` requests in order to handle
    ## data submission.
    result = toSeq(req.getBody().decodeQuery)

when defined webapp:
    proc isPage*(req: Request, key: string): bool =
        ## Determine if current page is as expected
        result = req.getCurrentPath() == key

    method getAgent*(req: Request): string =
        ## Retrieves the user agent from request header
        result = req.getHeader("user-agent")

    method getPlatform*(req: Request): string =
        ## Return the platform name, It can be one of the following common platform values:
        ## ``Android``, ``Chrome OS``, ``iOS``, ``Linux``, ``macOS``, ``Windows``, or ``Unknown``.
        # https://wicg.github.io/ua-client-hints/#sec-ch-ua-platform
        result = unquote(req.getHeader("sec-ch-ua-platform"))

    method isMacOS*(req: Request): bool =
        ## Determine if current request is made from ``macOS`` platform
        result = req.getPlatform() == "macOS"

    method isLinux*(req: Request): bool =
        ## Determine if current request is made from ``Linux`` platform
        result = req.getPlatform() == "Linux"

    method isWindows*(req: Request): bool =
        ## Determine if current request is made from ``Window`` platform
        result = req.getPlatform() == "Windows"

    method isChromeOS*(req: Request): bool =
        ## Determine if current request is made from ``Chrome OS`` platform
        result = req.getPlatform() == "Chrome OS"

    method isIOS*(req: Request): bool =
        ## Determine if current request is made from ``iOS`` platform
        result = req.getPlatform() == "iOS"

    method isAndroid*(req: Request): bool =
        ## Determine if current request is made from ``Android`` platform
        result = req.getPlatform() == "Android"

    method isMobile*(req: Request): bool =
        ## Determine if current request is made from a mobile device
        ## https://wicg.github.io/ua-client-hints/#sec-ch-ua-mobile
        result = req.getPlatform() in ["Android", "iOS"] and
                 req.getHeader("sec-ch-ua-mobile") == "true"

#
# Response - Higher-level
#
from ./core/http/server import Response, response, send404, send500,
                            addCacheControl, json, json404, json500, json_error,
                            redirect, redirects, abort, newCookie, getDeferredRedirect,
                            setSessionId, addCookieHeader
export json_error

when defined webapp:
    from ./core/http/server import view, css, js
    export view, css, js

export Response, response, send404, send500,
        addCacheControl, json, json404, json500, redirect,
        redirects, abort, newCookie, getDeferredRedirect

method send*(res: var Response, body: string, code = HttpCode(200), contentType = "text/html") =
    response(res, body, code, contentType)