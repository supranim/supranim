# Supranim is a simple MVC web framework
# for building web apps & microservices in Nim.
#
# (c) 2024 MIT License | Made by Humans from OpenPeeps
# https://supranim.com | https://github.com/supranim

import std/[options, httpcore, uri, tables]

import ../support/cookie

from ./http import Request, ip, body, send, forget, headers
export ip, body, send, forget, headers, `$`

type
  RootRequest* = http.Request

  Request* = object
    id: string
    ssid: string
    root*: RootRequest
    reqHeaders: Option[HttpHeaders]
    methodType: Option[HttpMethod]
    params*: Table[string, string]
    uri: Uri

proc getHeaders*(req: http.Request): Option[HttpHeaders] =
  ## Parse and set `HttpHeaders` (when available)
  result = req.headers()

proc newRequest*(root: http.Request, uri: Uri,
    headers: sink Option[HttpHeaders]): Request =
  ## Create a new `Request`
  result.root = root
  result.uri = uri
  result.reqHeaders = root.getHeaders

proc getId*(req: Request): string =
  ## Returns the `UserSession` id
  req.ssid

proc getUri*(req: Request): Uri =
  ## Returns `Uri` from `Request`
  result = req.uri

proc getUrl*(req: Request): string =
  ## Returns a string `Uri` from `Request`
  result = $(req.uri)

proc getUriPath*(req: Request): string =
  ## Returns `Uri` path from `Request`
  result = req.uri.path

proc getQuery*(req: Request): string =
  ## Returns `Uri` query from `Request`.
  ## use `getUriQuery` to get a decoded query
  result = req.uri.query

proc getQueryTable*(req: Request): Table[string, string] =
  for q in req.uri.query.decodeQuery:
    result[q[0]] = q[1]

proc hasHeaders*(req: Request): bool =
  ## Check if `Request` has any `HttpHeaders`
  result = req.reqHeaders.get() != nil

proc getHeaders*(req: Request): Option[HttpHeaders] =
  ## Retrieve all `HttpHeaders` from `Request`
  result = req.reqHeaders

proc hasHeader*(req: Request, key: string): bool =
  ## Check if `Request` contains a header by `key`
  result = req.reqHeaders.get().hasKey(key)

proc hasHeader*(headers: Option[HttpHeaders], key: string): bool =
  ## Determine if `key` exists in `headers`
  result = headers.get().hasKey(key)

proc getHeader*(req: Request, key: string): string =
  ## Returns return a header from Request
  let headers = req.reqHeaders.get()
  if headers.hasKey(key):
    result = headers[key]

proc getHeader*(headers: Option[HttpHeaders], key: string): string = 
  ## Get a header by `key` from `headers`
  if headers.hasHeader(key):
    result = headers.get()[key]

proc hasCookies*(req: Request): bool =
  ## Check if `Request` contains Cookies header
  result = req.reqHeaders.get().hasKey("cookie")

proc getCookies*(req: Request): string =
  ## Returns Cookies header from `Request`
  result = req.reqHeaders.get()["cookie"]

proc getIp*(req: Request): string =
  ## Retrieves the IP address from request
  # req.getSelectorHandle.getData(req.getSocketHandle).ip
  result = req.root.ip()

proc getAgent*(req: Request): string =
  ## Retrieves the user agent from request header
  result = req.getHeader("user-agent")

proc getPlatform*(req: Request): string =
  ## Return the platform name, It can be one of the following
  ## common platform values: `Android`, `Chrome OS`, `iOS`,
  ## `Linux`, `macOS`, `Windows`, or `Unknown`.
  ## https://wicg.github.io/ua-client-hints/#sec-ch-ua-platform
  result = req.getHeader("sec-ch-ua-platform")
