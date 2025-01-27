# Supranim is a simple MVC web framework
# for building web apps & microservices in Nim.
#
# (c) 2024 MIT License | Made by Humans from OpenPeeps
# https://supranim.com | https://github.com/supranim

import std/[macros, macrocache, asyncdispatch, strutils,
  tables, httpcore, uri, sequtils, options, json]

import pkg/jsony
import ./core/[request, response]
import ./core/http/router
import ./support/cookie

# import ./application except init, initSystemServices, configs
# export application

export request, response, tables
export asyncdispatch, options

import pkg/libsodium/[sodium, sodium_sizes]
export jsony

let keypair* = crypto_box_keypair()

#
# Request - High-level API
#
proc getBody*(req: Request): string =
  ## Retrieves `Request` body
  result = req.root.body().get()

proc getFields*(req: Request): seq[(string, string)] =
  ## Decodes `Request` body
  result = toSeq(req.root.body.get().decodeQuery)

proc getFieldsJson*(req: Request): JsonNode =
  try:
    result = fromJson(req.root.body.get())
  except jsony.JsonError:
    discard

proc getFieldsTable*(req: Request, fromJson: bool = false): Table[string, string] =
  ## Decodes `Request` body to `Table[string, string]`
  ## Optionally set `fromJson` to true if data is sent as JSON
  if fromJson:
    let jsonData = req.getFieldsJson()
    if likely(jsonData != nil):
      for k, v in jsonData:
        result[k] = v.getStr
  else:
    for x in req.root.body.get().decodeQuery:
      result[x[0]] = x[1]

proc hasCookies*(req: Request): bool =
  ## Check if `Request` contains Cookies header
  result = req.getHeaders.get().hasKey("cookie")

proc getCookies*(req: Request): string =
  ## Returns Cookies header from `Request`
  result = req.getHeaders.get()["cookie"]

proc getClientId*(req: Request): Option[string] =
  ## Returns the client-side `ssid` from `Request`
  if req.hasCookies:
    var clientCookies: CookiesTable = req.getCookies().parseCookies
    if clientCookies.hasKey("ssid"):
      let ssidCookie = clientCookies["ssid"]
      return some(ssidCookie.getValue())

proc getClientCookie*(req: Request): ref Cookie =
  ## Returns the client-side `ssid` Cookie from `Request`
  if req.hasCookies:
    var clientCookies: CookiesTable = req.getCookies().parseCookies
    if clientCookies.hasKey("ssid"):
      return clientCookies["ssid"]

#
# Controller Compile utils
macro newController*(name, body: untyped) =
  expectKind name, nnkIdent
  result =
    newProc(
      name = nnkPostfix.newTree(ident("*"), name),
      params = [
        newEmptyNode(),
        newIdentDefs(
          ident"req",
          ident"Request",
          newEmptyNode()
        ),
        newIdentDefs(
          ident"res",
          nnkVarTy.newTree(
            ident"Response" # a mutable `Response`
          ),
          newEmptyNode()
        ),
      ],
      body =
        nnkPragmaBlock.newTree(
          nnkPragma.newTree(ident"gcsafe"),
          body
        )
    )

template ctrl*(name, body: untyped) =
  newController(name, body)

macro go*(id: untyped) =
  ## To be used inside a controller handle
  ## to redirect from other verbs to a GET route, for example
  ## in a POST after login success you can say `go getAccount`. Nice!
  expectKind(id, nnkIdent)
  if queuedRoutes.hasKey(id.strVal):
    let routeNode = queuedRoutes[id.strVal]
    let methodType = routeNode[3]
    if methodType.eqIdent("HttpGet"):
      return nnkStmtList.newTree(
        newCall(ident("redirect"),
        routeNode[2][1]) # support named routes
      )
    error("HTTP redirects are available for GET handles. Got " & methodType.strVal, methodType)
  error("Unknown handle name " & id.strVal, id)

template isAuth*(): bool =
  (
    let ssid = req.getClientId
    if not ssid.isNone:
      let status = checkSession(ssid.get, req.getIp, req.getPlatform)
      status.isSome()
    else:
      false
  )
