# Supranim is a simple MVC-style web framework for building
# fast web applications, REST API microservices and other cool things.
#
# (c) 2022 Supranim is released under MIT License
#          Made by Humans from OpenPeep
#          https://supranim.com | https://github.com/supranim

import std/[httpcore, macros]
import jsony
import ../../../support/session

from ../../../support/str import unquote
from std/strutils import `%`
from std/json import JsonNode
from ../server import Request, Response, CacheControlResponse, HttpHeaders,
                    send, hasHeaders, getHeader, addHeader, getHeaders,
                    getRequest, newRedirect, getUserSessionUuid, addCookieHeader

export Request, hasHeaders, getHeader, jsony
export Response, CacheControlResponse, addHeader
export session

const
    HeaderHttpRedirect = "Location: $1"

#
# Http Responses
#
method response*(res: var Response, body: string, code = Http200, contentType = "text/html") =
    ## Sends a HTTP 200 OK response with the specified body.
    ## **Warning:** This can only be called once in the OnRequest callback.
    res.addHeader("Content-Type", contentType)
    res.getRequest().send(code, body, res.getHeaders())

method send404*(res: var Response, msg="404 | Not Found") =
    ## Sends a 404 HTTP Response with a default "404 | Not Found" message
    res.response(msg, Http404)

method send500*(res: var Response, msg="500 | Internal Error") =
    ## Sends a 500 HTTP Response with a default "500 | Internal Error" message
    res.response(msg, Http500)

template view*(res: var Response, key: string, code = Http200) =
    res.response(getViewContent(App, key))

method css*(res: var Response, data: string) =
    ## Send a response containing CSS contents with `Content-Type: text/css`
    res.response(data, contentType = "text/css;charset=UTF-8")

method js*(res: var Response, data: string) =
    res.response(data, contentType = "text/javascript;charset=UTF-8")

method addCacheControl*(res: var Response, opts: openarray[tuple[k: CacheControlResponse, v: string]]) =
    ## Method for adding a `Cache-Control` header to current `Response` instance
    ## https://nim-lang.org/docs/httpcore.html#add%2CHttpHeaders%2Cstring%2Cstring
    runnableExamples:
        res.addCacheControl(opts = [(MaxAge, "3200")])
    var cacheControlValue: string
    for opt in opts:
        cacheControlValue &= $opt.k & "=" & opt.v
    res.addHeader("Cache-Control", cacheControlValue)
#
# JSON Responses
#
method json*[R: Response, T](res: var R, body: T, code = Http200) {.base.} =
    ## Sends a JSON Response with a default 200 (OK) status code
    ## This template is using an untyped body parameter that is automatically
    ## converting ``seq``, ``objects``, ``string`` (and so on) to
    ## JSON (stringified) via ``jsony`` library.
    getRequest(res).send(code, toJson(body), "application/json;charset=UTF-8")

method json*[R: Response](res: R, body: JsonNode, code = Http200) =
    ## Sends a JSON response with a default 200 (OK) status code.
    ## This template is using the native JsonNode for creating the response body.
    getRequest(res).send(code, $body, "application/json;charset=UTF-8")

method json404*(res: var Response, body = "") =
    ## Sends a 404 JSON Response  with a default "Not found" message
    var jbody = if body.len == 0: """{"status": 404, "message": "Not Found"}""" else: body
    res.json(jbody, Http404)

method json500*(res: var Response, body = "") =
    ## Sends a 500 JSON Response with a default "Internal Error" message
    var jbody = if body.len == 0: """{"status": 500, "message": "Internal Error"}""" else: body
    res.json(jbody, Http500)

template json_error*(res: var Response, body: untyped, code: HttpCode = Http501) = 
    ## Sends a JSON response followed by of a HttpCode (that represents an error)
    getRequest(res).send(code, toJson(body), "application/json;charset=UTF-8")

#
# HTTP Redirects
#
method redirect*(res: var Response, target: string, code = Http307) =
    ## Set a HTTP Redirect with a default ``Http307`` Temporary Redirect status code
    getRequest(res).send(code, "", HeaderHttpRedirect % [target])

method redirect301*(res: var Response, target:string) =
    ## Set a HTTP Redirect with a ``Http301`` Moved Permanently status code
    getRequest(res).send(Http301, "", HeaderHttpRedirect % [target])

template redirects*(target: string) =
    ## Register a deferred 301 HTTP redirect in a middleware.
    res.newRedirect(target)

template abort*(httpCode: HttpCode = Http403) = 
    ## Abort the current execution and return a 403 HTTP 
    ## JSON response for REST (otherwise HTML for web apps).
    ## TODO Support custom 403 error pages, if enabled, 
    ## othwerwise send an empty 403 response so browsers
    ## can prompt their built-in error page.
    getRequest(res).send(httpCode, "You don't have authorisation to view this page", "text/html")
    return # block code execution after `abort`

#
# UserSession by Response
#
method getUserSession*(res: Response): UserSession =
    ## Returns the current `UserSession` instance 
    result = Session.getCurrentSession(res.getUserSessionUuid)

method getSession*(res: var Response): UserSession =
    ## Alias method for `getUserSession`
    result = res.getUserSession()

method getUserSessionId*(res: Response): Uuid =
    ## Returns the `UUID` from `UserSession` instance  
    result = res.getUserSessionUuid()

method hasExpiredSession*(res: Response): bool =
    ## Determine if current Session is expired
    result = res.getUserSession().hasExpired

method isExpiringSoon*(res: Response): bool =
    ## Determine if current Session will expire soon based on given interval
    ## TODO

method newCookie*(res: var Response, name, value: string) =
    ## Alias method that creates a new `Cookie` for the current `Response`
    res.addCookieHeader(res.getUserSession().newCookie(name, value))

# 
# Request Methods
# 
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