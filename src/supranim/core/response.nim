#
# Supranim is a high-performance web framework for building
# web applications and microservices in Nim
# 
#   (c) 2026 LGPL-v3-or-later License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#

import std/[strutils, htmlgen, times, options]
import pkg/openparser/json # std/json is exported from here

import std/httpcore except HttpMethod
import ../support/uuid

from ../network/webserver import Request, send, HttpMethod
export HttpCode

type
  Response* = object
    id*: Uuid
    code*: HttpCode = Http200
    headers*: HttpHeaders
    body*: string
    middlewareIndex*, afterwareIndex*: int
    isStreaming*: bool

const
  contentTypeHtml = "text/html; charset=utf-8"
  contentTypeJson = "application/json; charset=utf-8"
  contentTypeCalendar = "text/calendar; charset=utf-8"

proc getContentType*(): string =
  when defined webapp:
    result = contentTypeHtml
  else:
    result = contentTypeJson

proc getDefaultPage(title, heading, msg: string): string =
  html(
    head(
      title(title)
    ),
    body(
      h1(heading),
      p(msg)
    )
  )

proc getDefault*(code: HttpCode): string =
  ## Returns a default error page by `code`.
  ## Every known error code returns a minimal HTML page (never `""`),
  ## so `req.resp(code, getDefault(code))` is always safe.
  case code
  of Http400:
    result = getDefaultPage("400 - Bad Request", "400 | Bad Request",
      "The request could not be understood by the server.")
  of Http401:
    result = getDefaultPage("401 - Unauthorized", "401 | Unauthorized",
      "Authentication is required to access this resource.")
  of Http403:
    result = getDefaultPage("403 - Forbidden", "403 | Forbidden",
      "You do not have permission to access this resource.")
  of Http404:
    result = getDefaultPage("404 - Not Found", "404 | Not Found",
      "The requested resource could not be found.")
  of Http405:
    result = getDefaultPage("405 - Method Not Allowed", "405 | Method Not Allowed",
      "The HTTP method is not allowed for this resource.")
  of Http500:
    result = getDefaultPage("500 - Internal Server Error", "500 | Internal Server Error",
      "Something went wrong on the server.")
  of Http502:
    result = getDefaultPage("502 - Bad Gateway", "502 | Bad Gateway",
      "The server received an invalid response from upstream.")
  of Http503:
    result = getDefaultPage("503 - Service Unavailable", "503 | Service Unavailable",
      "The server is temporarily unavailable.")
  else:
    result = getDefaultPage($code.int & " - Error", $code.int & " | Error",
      "An error occurred while processing the request.")

proc toString*(headers: HttpHeaders): string =
  ## Converts HttpHeaders to string format
  var str: seq[string]
  for h in headers.pairs():
    str.add(h.key & ":" & indent(h.value, 1))
  result &= str.join("\n")

proc resp*(req: var Request, code: HttpCode,
        body: sink string, headers: HttpHeaders = nil) =
  ## Responds with the specified HttpCode and body.
  var serverDate = now().utc().format("ddd, dd MMM yyyy HH:mm:ss 'GMT'")
  var headers =
    if headers != nil: headers
    else: newHttpHeaders()
  headers.add("Date", $serverDate)
  req.send(code.int, body, headers)
  req.responseSent = true

#
# Response Headers
#
const emptyResponseBody* = newString(0)

proc addHeader*(res: var Response, key, value: string) =
  ## Add a new Http header to `Response`.
  ## https://nim-lang.org/docs/httpcore.html#HttpHeaders
  # if not res.headers.hasKey(key):
    # res.headers.table[key] = newTable[string, seq[string]]()
  res.headers.add(key, value)

proc getHeaders*(res: var Response): HttpHeaders =
  result = res.headers

proc redirectUri*(req: var Request, res: var Response, target: string, code = Http303) =
  res.addHeader("Location", target)
  req.resp(code, emptyResponseBody, res.headers)

template redirect*(target: string, code = Http303) {.dirty.} =
  ## Setup a HttpRedirect with a default `Http303` See Other
  ## This response code is often sent back as a result of `PUT` or `POST`.
  ## The method used to display this redirected page is always `GET`.
  res.addHeader("Location", target)
  req.resp(code, emptyResponseBody, res.headers)
  return # blocks code execution

template redirect301*(target: string) {.dirty.} =
  ## Set a HTTP redirect with a ``Http301`` Moved Permanently status code.
  res.addHeader("Location", target)
  req.resp(Http301, emptyResponseBody, res.headers)
  return # blocks code execution

#
# Response Body & Code
#
proc getCode*(res: Response): HttpCode =
  result = res.code

proc setCode*(res: var Response, code: HttpCode) =
  ## Set a `HttpCode` to `res` Response
  res.code = code

proc getBody*(res: Response): lent string =
  ## Get the body of `res` Response as a lent string
  res.body

proc setBody*(res: var Response, body: sink string) =
  ## Set a string body to `res` Response
  res.body =move body

template json*(body: typed, code: HttpCode = Http200): untyped =
  ## Prepare a JSON response with the specified body and HttpCode.
  ## The actual sending of the response is handled in the main request handler,
  ## allowing for any additional processing (like afterware) to be
  ## applied before the response is sent.
  ## 
  ## This template blocks code execution after setting up the response.
  when compileOption("app", "lib"):
    res[].setCode(code)
    res[].addHeader("Content-Type", $contentTypeJson)
    res[].setBody(json.toJson(body))
  else:
    res.setCode(code)
    res.addHeader("Content-Type", $contentTypeJson)
    res.setBody(json.toJson(body))
  return # blocks code execution

template sendJson*(body: typed, code: HttpCode = Http200): untyped =
  ## Sends the current response as JSON. This is typically used
  ## in middleware to immediately send a response without proceeding
  ## to the next middleware/controller.
  ## 
  ## TODO move this logic to middleware module
  when compileOption("app", "lib"):
    res[].setCode(code)
    res[].addHeader("Content-Type", $contentTypeJson)
    res[].setBody(json.toJson(body))
  else:
    res.setCode(code)
    res.addHeader("Content-Type", $contentTypeJson)
    res.setBody(json.toJson(body))
  req.send(res.getCode().int, res.getBody(), res.getHeaders())
  req.responseSent = true
  return # blocks code execution

template respond*(body: sink string, contentType: string = getContentType()): untyped {.dirty.} =
  ## Prepare a response with the specified body and content type.
  ## The actual sending of the response is handled in the main request handler.
  ## This template blocks code execution after setting up the response.
  when compileOption("app", "lib"):
    res[].addHeader("Content-Type", $contentType)
    res[].setBody(body)
  else:
    res.addHeader("Content-Type", $contentType)
    res.setBody(body)
  return

template respond*(code: HttpCode, body: sink string, contentType: string = getContentType()): untyped {.dirty.} =
  ## Prepare a response with the specified HttpCode, body, and content type.
  ## The actual sending of the response is handled in the main request handler.
  ## This template blocks code execution after setting up the response.
  when compileOption("app", "lib"):
    res[].setCode(code)
    res[].addHeader("Content-Type", $contentType)
    res[].setBody(body)
  else:
    res.setCode(code)
    res.addHeader("Content-Type", $contentType)
    res.setBody(body)
  return
