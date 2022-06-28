# Supranim is a simple Hyper Server and Web Framework developed
# for building safe & fast in-house projects.
# 
# Supranim - Response Handler
# This is an include-only file, part of the ./server.nim
# 
# (c) 2021 Supranim is released under MIT License
#          Developed by Humans from OpenPeep
#          
#          Website: https://supranim.com
#          Github Repository: https://github.com/supranim

import std/[httpcore, macros]
import jsony

from std/strutils import `%`
from std/json import JsonNode
from ./server import Request, Response, send, hasHeaders, getHeader, getRequest, newRedirect

export Request, Response
export hasHeaders, getHeader, jsony

const
    ContentTypeJSON = "Content-Type: application/json"
    ContentTypeTextHtml = "Content-Type: text/html"
    ContentTypeTextCSS = "Content-Type: text/css"
    HeaderHttpRedirect = "Location: $1"

#
# Http Responses
#
method response*[R: Response](res: R, body: string, code = Http200, contentType = ContentTypeTextHtml) =
    ## Sends a HTTP 200 OK response with the specified body.
    ## **Warning:** This can only be called once in the OnRequest callback.
    res.getRequest().send(code, body, contentType)

method send404*[R: Response](res: R, msg="404 | Not Found") =
    ## Sends a 404 HTTP Response with a default "404 | Not Found" message
    res.response(msg, Http404)

method send500*[R: Response](res: R, msg="500 | Internal Error") =
    ## Sends a 500 HTTP Response with a default "500 | Internal Error" message
    res.response(msg, Http500)

template view*[R: Response](res: R, key: string, code = Http200) =
    res.response(getViewContent(App, key))

method css*[R: Response](res: R, data: string) =
    ## Send a response containing CSS contents with ``Content-Type: text/css``
    res.response(data, contentType = ContentTypeTextCSS)

#
# JSON Responses
#
method json*[R: Response, T](res: R, body: T, code = Http200) {.base.} =
    ## Sends a JSON Response with a default 200 (OK) status code
    ## This template is using an untyped body parameter that is automatically
    ## converting ``seq``, ``objects``, ``string`` (and so on) to
    ## JSON (stringified) via ``jsony`` library.
    getRequest(res).send(code, toJson(body), ContentTypeJSON)

method json*[R: Response](res: R, body: JsonNode, code = Http200) =
    ## Sends a JSON response with a default 200 (OK) status code.
    ## This template is using the native JsonNode for creating the response body.
    getRequest(res).send(code, $(body), ContentTypeJSON)

method json404*[R: Response](res: R, body = "") =
    ## Sends a 404 JSON Response  with a default "Not found" message
    var jbody = if body.len == 0: """{"status": 404, "message": "Not Found"}""" else: body
    res.json(jbody, Http404)

method json500*[R: Response](res: R, body = "") =
    ## Sends a 500 JSON Response with a default "Internal Error" message
    var jbody = if body.len == 0: """{"status": 500, "message": "Internal Error"}""" else: body
    res.json(jbody, Http500)

method json_error*[R: Response](res: R, body: untyped, code: HttpCode = Http501) = 
    ## Sends a JSON response followed by of a HttpCode (that represents an error)
    getRequest(res).send(code, toJson(body), ContentTypeJSON)

#
# HTTP Redirects procedures
#
method redirect*[R: Response](res: R, target: string, code = Http307) =
    ## Set a HTTP Redirect with a default ``Http307`` Temporary Redirect status code
    getRequest(res).send(code, "", HeaderHttpRedirect % [target])

# macro redirects*(procDef: typed): untyped =
#     procDef.expectKind nnkProcDef
#     let procName = procDef[0].toStrLit
#     let procNameId = ident "procName"
#     let pnameDef = quote do:
#         let procNameId = `procName`
#         echo procNameId
#     # procDef.body.insert(0, pnameDef)
#     return procDef

# template redirects*(text: string) {.pragma.}
template redirects*(target: string) =
    ## Register a deferred 301 HTTP redirect in a middleware.
    res.newRedirect(target)

template abort*(httpCode: HttpCode = Http403) = 
    ## Abort the current execution and return a 403 HTTP 
    ## JSON response for REST (otherwise HTML for web apps).
    ## TODO Support custom 403 error pages, if enabled, 
    ## othwerwise send an empty 403 response so browsers
    ## can prompt their built-in error page.
    getRequest(res).send(httpCode, "You don't have authorisation to view this page", ContentTypeTextHtml)
    return # block code execution after `abort`

method redirect301*(res: Response, target:string) =
    ## Set a HTTP Redirect with a ``Http301`` Moved Permanently status code
    getRequest(res).send(Http301, "", HeaderHttpRedirect % [target])

method getAgent*(req: Request): string =
    ## Retrieves the user agent from request header
    result = req.getHeader("user-agent")

method getPlatform*(req: Request): string =
    ## Return the platform name, It can be one of the following common platform values:
    ## ``Android``, ``Chrome OS``, ``iOS``, ``Linux``, ``macOS``, ``Windows``, or ``Unknown``.
    # https://wicg.github.io/ua-client-hints/#sec-ch-ua-platform
    let currOs = req.getHeader("sec-ch-ua-platform")
    if currOs[0] == '"' and currOs[^1] == '"':
        result = currOs[1 .. ^2]

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