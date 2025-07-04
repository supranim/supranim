# Supranim is a simple MVC web framework
# for building web apps & microservices in Nim.
#
# (c) 2024 MIT License | Made by Humans from OpenPeeps
# https://supranim.com | https://github.com/supranim

import std/[strutils, options, json, httpcore, uri, tables]
import pkg/jsony
import ../support/cookie

from ./http import Request, ip, body, send, forget, headers
export ip, body, send, forget, headers, `$`

type
  RootRequest* = http.Request
  
  BodyFields* = Table[string, string]
  SomeBodyFields* = Option[BodyFields]

  Request* = object
    id: string
    ssid: string
    root*: RootRequest
    reqHeaders: Option[HttpHeaders]
    methodType: Option[HttpMethod]
    params*: Table[string, string]
    bodyFields: Option[Table[string, string]]
      # `bodyFields` is used to store the body fields
      # representing key/value pairs of data that
      # are sent within the body of the request.
    uri: Uri

proc getHeaders*(req: http.Request): Option[HttpHeaders] =
  ## Parse and set `HttpHeaders` (when available)
  result = req.headers()

proc newRequest*(root: http.Request, uri: Uri, headers: Option[HttpHeaders]): Request =
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
  req.reqHeaders.get().hasKey(key)

proc hasHeader*(headers: Option[HttpHeaders], key: string): bool =
  ## Determine if `key` exists in `headers`
  headers.get().hasKey(key)

proc getHeader*(req: Request, key: string): Option[string] =
  ## Returns return a header from Request
  let headers = req.reqHeaders.get()
  if headers.hasKey(key):
    return some($(headers[key]))
  none(string)

proc getHeader*(headers: Option[HttpHeaders], key: string): Option[string] = 
  ## Get a header by `key` from `headers`
  if headers.hasHeader(key):
    return some($(headers.get()[key]))
  none(string)

proc hasCookies*(req: Request): bool =
  ## Check if `Request` contains Cookies header
  result = req.hasHeader("cookie")

proc getCookies*(req: Request): Option[string] =
  ## Returns Cookies header from `Request`
  result = req.getHeader("cookie")

proc getIp*(req: Request): string =
  ## Retrieves the IP address from request
  # req.getSelectorHandle.getData(req.getSocketHandle).ip
  result = req.root.ip()

proc getAgent*(req: Request): Option[string] =
  ## Retrieves the user agent from request header
  result = req.getHeader("user-agent")

proc getBrowserName*(req: Request): Option[string] =
  ## Retrieves the browser name from `sec-ch-ua` header
  ## https://wicg.github.io/ua-client-hints/#sec-ch-ua
  result = req.getHeader("sec-ch-ua")

proc getPlatform*(req: Request): Option[string] =
  ## Return the platform name, It can be one of the following
  ## common platform values: `Android`, `Chrome OS`, `iOS`,
  ## `Linux`, `macOS`, `Windows`, or `Unknown`.
  ## https://wicg.github.io/ua-client-hints/#sec-ch-ua-platform
  result = req.getHeader("sec-ch-ua-platform")
  if result.isNone():
    # fallback to the `user-agent` header to get the OS platform
    let agent = req.getAgent().get("")
    if agent.contains("Windows"):
      result = some("Windows")
    elif agent.contains("Macintosh") or agent.contains("Mac OS X"):
      result = some("macOS")
    elif agent.contains("Linux"):
      result = some("Linux")
    elif agent.contains("Android"):
      result = some("Android")
    elif agent.contains("iOS") or agent.contains("iPhone") or agent.contains("iPad"):
      result = some("iOS")
    else:
      result = some("Unknown")

proc getClientData*(req: Request): JsonNode =
  ## Returns the client data from the request
  %*{
    "ip": req.getIp(),
    "platform": req.getPlatform(),
    "agent": req.getAgent().get("unknown"),
    "sec-ch-ua": req.getBrowserName().get("unknown")
  }

proc getBodyFields*(req: var Request): SomeBodyFields =
  ## Returns the body fields from `Request`.
  ## When called for the first time it will decode the body
  ## and store the result in `bodyFields` table.
  ## 
  ## If `bodyFields` is already set, it will return the
  ## existing table.
  if req.bodyFields.isNone():
    var res = BodyFields()
    for x in req.root.body.get().decodeQuery:
      res[x[0]] = x[1]
    req.bodyFields = some(res)
  return req.bodyFields

proc getBodyFieldsJson*(req: var Request): SomeBodyFields =
  ## Returns the body fields from `Request`.
  ## When called for the first time it will decode the body
  ## and store the result in `bodyFields` table.
  ##
  ## Note this must be called only when the provided body is JSON.
  ## Invalid JSON will be rejected and the returned value
  ## will be `none`.
  if req.bodyFields.isNone():
    try:
      var res = BodyFields()
      let jsondata = jsony.fromJson(req.root.body.get())
      if likely(jsondata != nil):
        for k, v in jsondata:
          res[k] = v.getStr()
      req.bodyFields = some(res)
      return req.bodyFields
    except jsony.JsonError: discard

proc getFieldsTable*(req: var Request): SomeBodyFields {.inline.} =
  ## An alias of `getBodyFields`
  req.getBodyFields()

proc getFieldsTableJson*(req: var Request): SomeBodyFields {.inline.} =
  ## An alias of `getBodyFieldsJson`
  req.getBodyFieldsJson()

proc getJsonBody*(req: Request): Option[JsonNode] =
  ## Parse the body as JSON and return it.
  ## If the body is not valid JSON, it will return `none`.
  try:
    let jsondata = jsony.fromJson(req.root.body.get())
    if jsondata != nil:
      return some(jsondata)
  except jsony.JsonError: discard
  none(JsonNode)

proc getJsonBody*[T](req: Request, toObj: typedesc[T]): Option[T] =
  ## Parse the body as JSON and return it.
  ## If the body is not valid JSON, it will return `none`.
  try:
    let objFromJson = jsony.fromJson(req.root.body.get(), toObj)
    return some(objFromJson)
  except jsony.JsonError as e:
    echo e.msg
    discard
  none(toObj)