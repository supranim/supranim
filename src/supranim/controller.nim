#
# Supranim is a full-featured web framework for building
# web apps & microservices in Nim.
# 
#   (c) 2025 MIT License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#

import std/[macros, macrocache, asyncdispatch, strutils,
        tables, httpcore, uri, sequtils, options, json]

import pkg/jsony
import pkg/libsodium/[sodium, sodium_sizes]

import ./http/[request, response, router]
import ./support/cookie

export jsony, uri
export request, response, tables
export asyncdispatch, options

let keypair* = crypto_box_keypair()

type
  BodyFields* = Table[string, string]
  SomeBodyFields* = Option[BodyFields]

#
# Request - High-level API
#
proc setParams*(req: var Request, params: Table[string, string]) =
  ## Sets the route parameters in `Request`
  req.appData = addr(params)

proc params*(req: Request): Table[string, string] =
  ## Returns the route parameters from `Request`
  if req.appData != nil:
    var res = cast[ptr Table[string, string]](req.appData)
    result = res[]

proc getRequestBody*(req: var Request): string =
  ## Retrieves `Request` body
  req.getBody().get("")

proc getFields*(req: var Request): seq[(string, string)] =
  ## Decodes `Request` body
  let body = req.getBody()
  if body.isSome:
    return toSeq(body.get().decodeQuery)

proc getFieldsJson*(req: Request): JsonNode =
  try:
    # result = fromJson(req.root.body.get())
    discard
  except jsony.JsonError:
    discard

proc getBodyFields*(req: var Request): SomeBodyFields =
  ## Returns the body fields from `Request`.
  ## When called for the first time it will decode the body
  ## and store the result in `bodyFields` table.
  ## 
  ## If `bodyFields` is already set, it will return the
  ## existing table.
  var res = BodyFields()
  for x in req.getBody.get().decodeQuery:
    res[x[0]] = x[1]
  some(res)

proc getBodyFieldsJson*(req: var Request): SomeBodyFields =
  ## Returns the body fields from `Request`.
  ## When called for the first time it will decode the body
  ## and store the result in `bodyFields` table.
  ##
  ## Note this must be called only when the provided body is JSON.
  ## Invalid JSON will be rejected and the returned value
  ## will be `none`.
  # if req.bodyFields.isNone():
  #   try:
  #     var res = BodyFields()
  #     let jsondata = jsony.fromJson(req.root.body.get())
  #     if likely(jsondata != nil):
  #       for k, v in jsondata:
  #         res[k] = v.getStr()
  #     req.bodyFields = some(res)
  #     return req.bodyFields
  #   except jsony.JsonError: discard
  discard

proc getFieldsTable*(req: var Request): SomeBodyFields {.inline.} =
  ## An alias of `getBodyFields`
  req.getBodyFields()

proc getFieldsTableJson*(req: var Request): SomeBodyFields {.inline.} =
  ## An alias of `getBodyFieldsJson`
  req.getBodyFieldsJson()

proc getQueryTable*(req: var Request): TableRef[string, string] {.inline.} =
  ## Retrieve query parameters as a table
  result = req.getQuery().get()

proc getClientId*(req: var Request): Option[string] =
  ## Returns the client-side `ssid` from `Request`
  if req.hasCookies:
    var clientCookies: CookiesTable = parseCookies(req.getCookies().get())
    if clientCookies.hasKey("ssid"):
      let ssidCookie = clientCookies["ssid"]
      return some(ssidCookie.getValue())

proc getSessionCookie*(req: var Request): ref Cookie =
  ## Returns the client-side `ssid` Cookie from `Request`
  if req.hasCookies:
    var clientCookies: CookiesTable = parseCookies(req.getCookies().get())
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
          nnkVarTy.newTree(
            ident"Request"
          ),
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

macro go*(id: untyped, params: typed) =
  ## Redirects to a specific GET route
  ## using the controller identifier. This macro adds
  ## support for redirecting with query parameters.
  if queuedRoutes.hasKey(id.strVal):
    let
      route = queuedRoutes[id.strVal]
      mtype = route[3]
    if mtype.eqIdent("HttpGet"):
      let path = route[2][1].strVal & "?"
      return nnkStmtList.newTree(
        newCall(
          ident("redirect"),
          nnkInfix.newTree(
            ident"&",
            newLit(path),
            newCall(ident"encodeQuery", params)
          )
        )
      )
    error("HTTP redirects are available for GET handles. Got " & mtype.strVal, mtype)
  error("Unknown handle name " & id.strVal, id)

macro go*(id: untyped) =
  ## Redirects to a specific GET route
  ## using the controller identifier. 
  expectKind(id, nnkIdent)
  if queuedRoutes.hasKey(id.strVal):
    let
      route = queuedRoutes[id.strVal]
      mtype = route[3]
    if mtype.eqIdent("HttpGet"):
      return nnkStmtList.newTree(
        newCall(
          ident("redirect"),
          route[2][1]
        )
      )
    error("HTTP redirects are available for GET handles. Got " & mtype.strVal, mtype)
  error("Unknown handle name " & id.strVal, id)

template redirectTo*(controllerIdentName: typed) =
  ## An alias of `go` macro that redirects to
  ## specific `GET` route using the controller name.
  go controllerIdentName

template isAuth*(): bool =
  (
    withDB do:
      let ssid = req.getClientId()
      if not ssid.isNone:
        # let userData = %*{
        #   "ip": req.getIp(),
        #   "platform": req.getPlatform().get(),
        #   "agent": req.getAgent().get(),
        #   "sec-ch-ua": req.getBrowserName().get()
        # }
        # checkSession(ssid.get, userData)
        let anySessions = Models.table("user_sessions").select
              .where("session_id", ssid.get()).getAll() 
        if anySessions.isEmpty():
          false
        else:
          for storedSession in anySessions:
            echo storedSession
          false
      else:
        false
  )
