#
# Supranim - A high-performance MVC web framework for Nim,
# designed to simplify web application and REST API development.
# 
#   (c) 2025 MIT License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#

import std/[httpcore, strutils, htmlgen, json, times, options]
import pkg/jsony

import ../support/uuid

from ../network/http/webserver import Request, send
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
  HeaderHttpRedirect = "Location: $1"
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
  ## Returns a default error page by `code`
  case code
  of Http403:
    result = getDefaultPage("403 - Forbidden", "403 | Forbidden", "Lorem ipsum")
    return "Forbidden"
  of Http404:
    result = getDefaultPage("404 - Not found", "404 | Not found", "Lorem ipsum")
  else:
    result = "" # todo

proc toString*(headers: HttpHeaders): string =
  ## Converts HttpHeaders to string format
  var str: seq[string]
  for h in headers.pairs():
    str.add(h.key & ":" & indent(h.value, 1))
  result &= str.join("\n")

proc resp*(req: Request, code: HttpCode,
        body: sink string, headers: HttpHeaders = nil) =
  ## Responds with the specified HttpCode and body.
  var serverDate = now().utc().format("ddd, dd MMM yyyy HH:mm:ss 'GMT'")
  let bodyLen = $body.len
  var headers = headers
  if headers == nil:
    headers = HttpHeaders()
  headers.add("Content-Length", $bodyLen)
  headers.add("Date", $serverDate)
  req.send(code.int, body, headers)

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

proc redirectUri*(req: Request, res: var Response, target: string, code = Http303) =
  res.addHeader("Location", target)
  req.resp(code, emptyResponseBody, res.headers)

template redirect*(target: string, code = Http303) {.dirty.} =
  ## Setup a HttpRedirect with a default `Http303` See Other
  ## This response code is often sent back as a result of `PUT` or `POST`.
  ## The method used to display this redirected page is always `GET`.
  res.addHeader("Location", target)
  req.resp(code, emptyResponseBody, res.headers)
  return # blocks code execution

template redirect301*(target:string) =
  ## Set a HTTP Redirect with a ``Http301`` Moved Permanently status code
  # req.resp(Http301, emptyResponseBody, HeaderHttpRedirect % [target])
  return # blocks code execution

#
# Response Body & Code
#
proc getCode*(res: Response): HttpCode =
  result = res.code

proc setCode*(res: var Response, code: HttpCode) =
  ## Set a `HttpCode` to `res` Response
  res.code = code

proc getBody*(res: Response): string =
  res.body

proc setBody*(res: var Response, body: string) =
  ## Set a string body to `res` Response
  res.body = body

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
    res[].setBody(jsony.toJson(body))
  else:
    res.setCode(code)
    res.addHeader("Content-Type", $contentTypeJson)
    res.setBody(jsony.toJson(body))
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
    res[].setBody(jsony.toJson(body))
  else:
    res.setCode(code)
    res.addHeader("Content-Type", $contentTypeJson)
    res.setBody(jsony.toJson(body))
  req.send(res.getCode().int, res.getBody(), res.getHeaders())
  return # blocks code execution

template respond*(body: string, contentType: string = getContentType()): untyped {.dirty.} =
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

template respond*(code: HttpCode, body: string,
  contentType: string = getContentType()
): untyped {.dirty.} =
  when compileOption("app", "lib"):
    res[].setCode(code)
    res[].addHeader("Content-Type", $contentType)
    res[].setBody(body)
  else:
    res.setCode(code)
    res.addHeader("Content-Type", $contentType)
    res.setBody(body)
  return
