# Supranim is a simple MVC-style web framework for building
# fast web applications, REST API microservices and other cool things.
#
# (c) 2022 Supranim is released under MIT License
#          Made by Humans from OpenPeep
#          https://supranim.com | https://github.com/supranim

import pkg/[pkginfo, jsony]
import std/[httpcore, macros]
import ../../support/session

from std/strutils import `%`

when requires "pkginfo":
  from pkg/packedjson import JsonNode, `$`
else:
  from std/json import JsonNode, `$`

export HttpCode, Response

let
  HeaderHttpRedirect = "Location: $1"
  ContentTypeJson = "application/json"
  ContentTypeHTML = "text/html"

#
# Response - Http Interface API
#

proc response*(res: Response, body: string, code = Http200, contentType = ContentTypeHTML): HttpResponse
proc send404*(res: Response, msg="404 | Not Found"): HttpResponse
proc send500*(res: Response, msg="500 | Internal Error"): HttpResponse
proc send503*(res: Response, msg="503 | Service Unavailable"): HttpResponse

when defined webapp:
  proc css*(res: Response, data: string): HttpResponse
  proc js*(res: Response, data: string): HttpResponse
  proc svg*(res: Response, data: string): HttpResponse
proc json*[R: Response, T](res: R, body: T, code = Http200): HttpResponse
proc json*(res: Response, body: JsonNode, code = Http200): HttpResponse
#
# Response - Redirect Interface API
#
proc newDeferredRedirect*(res: Response, target: string)
proc getDeferredRedirect*(res: Response): string
proc redirect*(res: Response, target: string, code = Http303)
proc redirect301*(res: Response, target:string)

#
# Response - User Session API
#
proc getUserSession*(res: Response): UserSession
proc getSession*(res: Response): UserSession
proc getSessionId*(res: Response): Uuid

#
# Http Responses
#
proc sendResponse*(req: Request, res: Response, body: HttpResponse) =
  req.send(res.code, string(body), res.getHeaders())

proc response*(res: Response, body: string, code = Http200, contentType = ContentTypeHTML): HttpResponse =
  ## Sends a HTTP 200 OK response with the specified body.
  ## **Warning:** This can only be called once in the OnRequest callback.
  res.addHeader("Content-Type", contentType)
  res.code = code
  result = HttpResponse(body)

proc send404Response*(req: Request, res: Response, msg="404 | Not Found") =
  res.code = Http404
  req.sendResponse(res, HttpResponse(msg))

proc send404*(res: Response, msg="404 | Not Found"): HttpResponse =
  ## Sends a 404 HTTP Response with a default "404 | Not Found" message
  res.response(msg, Http404)

proc send500*(res: Response, msg="500 | Internal Error"): HttpResponse =
  ## Sends a 500 HTTP Response with a default "500 | Internal Error" message
  res.response(msg, Http500)

proc send503*(res: Response, msg="503 | Service Unavailable"): HttpResponse =
  ## Sends a 503 HTTP Response with a default "503 | Service Unavailable" message
  res.response(msg, Http503)

when defined webapp:
  template view*(res: Response, key: string, code = Http200) =
    res.response(getViewContent(App, key))

  proc css*(res: Response, data: string): HttpResponse =
    ## Send a response containing CSS contents with `Content-Type: text/css`
    res.response(data, contentType = "text/css;charset=UTF-8")

  proc js*(res: Response, data: string): HttpResponse =
    res.response(data, contentType = "text/javascript;charset=UTF-8")

  proc svg*(res: Response, data: string): HttpResponse =
    res.response(data, contentType = "image/svg+xml;charset=UTF-8")

proc addCacheControl*(res: Response, opts: openarray[tuple[k: CacheControlResponse, v: string]]) =
  ## proc for adding a `Cache-Control` header to current `Response` instance
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
proc json*[R: Response, T](res: R, body: T, code = Http200): HttpResponse =
  ## Sends a JSON Response with a default 200 (OK) status code
  ## This template is using an untyped body parameter that is automatically
  ## converting ``seq``, ``objects``, ``string`` (and so on) to
  ## JSON (stringified) via ``jsony`` library.
  res.response(toJson(body), code, ContentTypeJson)

proc json*(res: Response, body: JsonNode, code = Http200): HttpResponse =
  ## Sends a JSON response with a default 200 (OK) status code.
  ## This template is using the native JsonNode for creating the response body.
  res.response($body, code, ContentTypeJson)

template json404*(res: Response, body: untyped = ""): untyped =
  ## Sends a 404 JSON Response  with a default "Not found" message
  var jbody = if body.len == 0: """{"status": 404, "message": "Not Found"}""" else: body
  res.json(jbody, Http404)

template json500*(res: Response, body: untyped = ""): untyped =
  ## Sends a 500 JSON Response with a default "Internal Error" message
  var jbody = if body.len == 0: """{"status": 500, "message": "Internal Error"}""" else: body
  res.json(jbody, Http500)

template json503*(res: Response, body: untyped = ""): untyped =
  ## Sends a 503 JSON response with a default "Service Unavailable" message
  var jbody = if body.len == 0: """{"status": 503, "message": "Service Unavailable"}""" else: body
  res.json(jbody, Http503)

#
# HTTP Redirects
#
proc newDeferredRedirect*(res: Response, target: string) =
  ## Set a deferred redirect
  res.deferRedirect = target

proc getDeferredRedirect*(res: Response): string =
  ## Get a deferred redirect
  res.deferRedirect

proc redirect*(res: Response, target: string, code = Http303) =
  ## Setup a HttpRedirect with a default 303 `HttpCode
  res.addHeader("Location", target)
  getRequest(res).send(code, "", res.getHeaders())

proc redirect301*(res: Response, target:string) =
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
  getRequest(res).send(httpCode, "You don't have authorization to view this page", "text/html")
  return # block code execution after `abort`

template abort*(target: string, httpCode = Http303) =
  ## Abort the current exection and return a Http 303 rediret
  res.redirect(target, httpCode)
  return # block code exection

#
# UserSession by Response
#
proc shouldRedirect*(res: Response): bool =
  ## Determine if response should resolve any deferred redirects
  result = res.deferRedirect.len != 0

proc getUserSession*(res: Response): UserSession =
  ## Returns the current `UserSession` instance 
  ## from given `Response`
  result = Session.getCurrentSessionByUuid(res.sessionId)

proc getSession*(res: Response): UserSession =
  ## Alias proc for `getUserSession`
  result = res.getUserSession()

proc getSessionId*(res: Response): Uuid =
  ## Returns the `UUID` from `UserSession` instance  
  ## Returns the unique ID representing the `UserSession`
  ## for given `Response`
  result = res.sessionId

proc addCookieHeader*(res: Response, cookie: ref Cookie) =
  ## Add a new `Cookie` to given Response instance.
  ## Do not call this proc directly. Instead,
  ## you can use `newCookie()` proc from `supranim/support/session` module
  if not res.headers.hasKey("set-cookie"):
    res.headers.table["set-cookie"] = newSeq[string]()
  res.headers.table["set-cookie"].add($cookie)

proc newCookie*(res: Response, name, value: string) =
  ## Alias proc that creates a new `Cookie` for the current `Response`
  res.addCookieHeader(res.getUserSession().newCookie(name, value))

proc deleteCookieHeader*(res: Response, name: string) =
  ## Invalidate a Cookie on client side for the given `Response` 
  ## Do not call this proc directly. Instead,
  ## you can use `deleteCookie()` proc from `supranim/support/session` module
  ## TODO

proc setSessionId*(res: Response, id: Uuid) =
  res.sessionId = id