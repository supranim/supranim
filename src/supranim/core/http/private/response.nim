# Supranim is a simple MVC-style web framework for building
# fast web applications, REST API microservices and other cool things.
#
# (c) 2022 Supranim is released under MIT License
#          Made by Humans from OpenPeep
#          https://supranim.com | https://github.com/supranim

from std/json import JsonNode
import jsony
import std/[httpcore, macros]
import ../../../support/session

from std/strutils import `%`
export HttpCode, Response

let
    HeaderHttpRedirect = "Location: $1"
    ContentTypeJson = "application/json"
    ContentTypeHTML = "text/html"

#
# Response - Http Interface API
#

method response*(res: var Response, body: string, code = Http200, contentType = ContentTypeHTML)
method send404*(res: var Response, msg="404 | Not Found")
method send500*(res: var Response, msg="500 | Internal Error")
when defined webapp:
    method css*(res: var Response, data: string)
    method js*(res: var Response, data: string)
    method svg*(res: var Response, data: string)
method json*[R: Response, T](res: var R, body: T, code = Http200) {.base.}
method json*(res: var Response, body: JsonNode, code = Http200)
#
# Response - Redirect Interface API
#
method newDeferredRedirect*(res: var Response, target: string)
method getDeferredRedirect*(res: Response): string
method redirect*(res: var Response, target: string, code = Http303)
method redirect301*(res: var Response, target:string)

#
# Response - User Session API
#
method getUserSession*(res: Response): UserSession
method getSession*(res: var Response): UserSession
method getSessionId*(res: Response): Uuid

#
# Http Responses
#
method response*(res: var Response, body: string, code = Http200, contentType = ContentTypeHTML) =
    ## Sends a HTTP 200 OK response with the specified body.
    ## **Warning:** This can only be called once in the OnRequest callback.
    res.addHeader("Content-Type", contentType)
    getRequest(res).send(code, body, res.getHeaders())

method send404*(res: var Response, msg="404 | Not Found") =
    ## Sends a 404 HTTP Response with a default "404 | Not Found" message
    res.response(msg, Http404)

method send500*(res: var Response, msg="500 | Internal Error") =
    ## Sends a 500 HTTP Response with a default "500 | Internal Error" message
    res.response(msg, Http500)

when defined webapp:
    template view*(res: var Response, key: string, code = Http200) =
        res.response(getViewContent(App, key))

    method css*(res: var Response, data: string) =
        ## Send a response containing CSS contents with `Content-Type: text/css`
        res.response(data, contentType = "text/css;charset=UTF-8")

    method js*(res: var Response, data: string) =
        res.response(data, contentType = "text/javascript;charset=UTF-8")

    method svg*(res: var Response, data: string) =
        res.response(data, contentType = "image/svg+xml;charset=UTF-8")

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
    res.response(toJson(body), code, ContentTypeJson)

method json*(res: var Response, body: JsonNode, code = Http200) =
    ## Sends a JSON response with a default 200 (OK) status code.
    ## This template is using the native JsonNode for creating the response body.
    res.response($body, code, ContentTypeJson)

template json_error*(res: var Response, body: untyped, code: HttpCode = Http501) = 
    ## Sends a JSON response followed by of a HttpCode (that represents an error)
    response(res, toJson(body), code, ContentTypeJson)

template json404*(res: var Response, body: untyped = "") =
    ## Sends a 404 JSON Response  with a default "Not found" message
    var jbody = if body.len == 0: """{"status": 404, "message": "Not Found"}""" else: body
    json_error(res, jbody, Http404)

template json500*(res: var Response, body: untyped = "") =
    ## Sends a 500 JSON Response with a default "Internal Error" message
    var jbody = if body.len == 0: """{"status": 500, "message": "Internal Error"}""" else: body
    json_error(res, jbody, Http500)

#
# HTTP Redirects
#
method newDeferredRedirect*(res: var Response, target: string) =
    ## Set a deferred redirect
    res.deferRedirect = target

method getDeferredRedirect*(res: Response): string =
    ## Get a deferred redirect
    res.deferRedirect

method redirect*(res: var Response, target: string, code = Http303) =
    ## Setup a HttpRedirect with a default 303 `HttpCode`
    getRequest(res).send(code, "", HeaderHttpRedirect % [target])

method redirect301*(res: var Response, target:string) =
    ## Set a HTTP Redirect with a ``Http301`` Moved Permanently status code
    getRequest(res).send(Http301, "", HeaderHttpRedirect % [target])

template redirects*(target: string) =
    ## Register a deferred 301 HTTP redirect in a middleware.
    res.newDeferredRedirect(target)

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
method shouldRedirect*(res: Response): bool =
    ## Determine if response should resolve any deferred redirects
    result = res.deferRedirect.len != 0

method getUserSession*(res: Response): UserSession =
    ## Returns the current `UserSession` instance 
    ## from given `Response`
    result = Session.getCurrentSessionByUuid(res.sessionId)

method getSession*(res: var Response): UserSession =
    ## Alias method for `getUserSession`
    result = res.getUserSession()

method getSessionId*(res: Response): Uuid =
    ## Returns the `UUID` from `UserSession` instance  
    ## Returns the unique ID representing the `UserSession`
    ## for given `Response`
    result = res.sessionId

method addCookieHeader*(res: var Response, cookie: ref Cookie) =
    ## Add a new `Cookie` to given Response instance.
    ## Do not call this method directly. Instead,
    ## you can use `newCookie()` method from `supranim/support/session` module
    if not res.headers.hasKey("set-cookie"):
        res.headers.table["set-cookie"] = newSeq[string]()
    res.headers.table["set-cookie"].add($cookie)

method newCookie*(res: var Response, name, value: string) =
    ## Alias method that creates a new `Cookie` for the current `Response`
    res.addCookieHeader(res.getUserSession().newCookie(name, value))

method deleteCookieHeader*(res: var Response, name: string) =
    ## Invalidate a Cookie on client side for the given `Response` 
    ## Do not call this method directly. Instead,
    ## you can use `deleteCookie()` method from `supranim/support/session` module
    ## TODO

method setSessionId*(res: var Response, id: Uuid) =
    res.sessionId = id