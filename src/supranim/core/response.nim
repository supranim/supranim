# Supranim is a simple MVC web framework
# for building web apps & microservices in Nim.
#
# (c) 2024 MIT License | Made by Humans from OpenPeeps
# https://supranim.com | https://github.com/supranim

import std/[httpcore, strutils, htmlgen, json]
import pkg/jsony

import ../support/uuid

from ./request import Request, send
export HttpCode

type
  Response* = object
    id*: Uuid
    code*: HttpCode = Http200
    headers*: HttpHeaders
    body*: string
    middlewareIndex*, afterwareIndex*: int

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

proc addHeader*(res: Response, key, value: string) =
  ## Add a new Http header to `Response`.
  ## https://nim-lang.org/docs/httpcore.html#HttpHeaders
  # if not res.headers.hasKey(key):
    # res.headers.table[key] = newTable[string, seq[string]]()
  res.headers.add(key, value)

proc getHeaders*(res: Response): string =
  ## Returns stringified HttpHeaders
  if res.headers != nil:
    var str: seq[string]
    for h in res.headers.pairs():
      str.add(h.key & ":" & indent(h.value, 1))
    result &= str.join("\n")

proc getHttpHeaders*(res: var Response): HttpHeaders =
  result = res.headers

proc redirectUri*(req: Request, res: Response, target: string, code = Http303) =
  res.addHeader("Location", target)
  req.root.send(code, "", res.getHeaders())

template redirect*(target: string, code = Http303) {.dirty.} =
  ## Setup a HttpRedirect with a default `Http303` See Other
  ## This response code is often sent back as a result of `PUT` or `POST`.
  ## The method used to display this redirected page is always `GET`.
  res.addHeader("Location", target)
  req.root.send(code, "", res.getHeaders())
  return # blocks code execution

template redirect301*(target:string) =
  ## Set a HTTP Redirect with a ``Http301`` Moved Permanently status code
  req.root.send(Http301, "", HeaderHttpRedirect % [target])
  return # blocks code execution

proc getCode*(res: Response): HttpCode = res.code

proc setCode*(res: var Response, code: HttpCode) =
  ## Set a `HttpCode` to `res` Response
  res.code = code

proc getBody*(res: Response): string =
  res.body

proc setBody*(res: var Response, body: string) =
  ## Set a string body to `res` Response
  res.body = body

template json*(body: typed, code: HttpCode = Http200): untyped =
  when compileOption("app", "lib"):
    res[].setCode(code)
    res[].addHeader("Content-Type", $contentTypeJson)
    res[].setBody(jsony.toJson(body))
  else:
    res.setCode(code)
    res.addHeader("Content-Type", $contentTypeJson)
    res.setBody(jsony.toJson(body))
  return

template respond*(body: string, contentType: string = getContentType()): untyped {.dirty.} =
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
