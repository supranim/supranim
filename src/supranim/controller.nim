#
# Supranim is a high-performance web framework for building
# web applications and microservices in Nim
# 
#   (c) 2026 LGPL-v3-or-later License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#

import std/[macros, macrocache, asyncdispatch, strutils,
        tables, httpcore, uri, sequtils, options]

import pkg/openparser/json
import ./core/[request, response, router, fileserver]
import ./support/cookie

from ./core/application import appInstance
from ./network/http/webserver import streamFile

export json, uri, request, response, tables,
        asyncdispatch, options, streamFile
export fileserver

type
  BodyData* = TableRef[string, string]
  SomeBodyData* = Option[BodyData]

#
# Request - High-level API
#
proc setParams*(req: var Request, params: sink Table[string, string]) =
  ## Sets the route parameters in `Request`
  req.routeParams = params

proc params*(req: Request): lent Table[string, string] =
  ## Returns the route parameters from `Request`
  req.routeParams

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
  except json.OpenParserJsonError:
    discard

proc getSomeBodyData*(req: var Request): SomeBodyData =
  ## Returns the body fields from `Request`.
  ## When called for the first time it will decode the body
  ## and store the result in `BodyData` table.
  ## 
  ## If `BodyData` is already set, it will return the
  ## existing table.
  var res = BodyData()
  for x in req.getBody.get().decodeQuery:
    res[x[0]] = x[1]
  some(res)

proc getBodyDataJson*(req: var Request): SomeBodyData =
  ## Returns the body fields from `Request`.
  ## When called for the first time it will decode the body
  ## and store the result in `BodyData` table.
  ##
  ## Note this must be called only when the provided body is JSON.
  ## Invalid JSON will be rejected and the returned value
  ## will be `none`.
  # if req.BodyData.isNone():
  #   try:
  #     var res = BodyData()
  #     let jsondata = json.fromJson(req.root.body.get())
  #     if likely(jsondata != nil):
  #       for k, v in jsondata:
  #         res[k] = v.getStr()
  #     req.BodyData = some(res)
  #     return req.BodyData
  #   except json.JsonError: discard
  discard

proc getFieldsTable*(req: var Request): SomeBodyData {.inline.} =
  ## An alias of `getSomeBodyData`
  req.getSomeBodyData()

proc getFieldsTableJson*(req: var Request): SomeBodyData {.inline.} =
  ## An alias of `getBodyDataJson`
  req.getBodyDataJson()

proc getBodyData*[T: BodyData|JsonNode](req: var Request, dataType: typedesc[T]): Option[T] =
  ## Returns the body data from `Request` as `JsonNode`
  # result = json.fromJson(req.getRequestBody())
  when T is BodyData:
    result = req.getSomeBodyData()
  elif T is JsonNode:
    return some(json.fromJson(req.getBody.get()))

proc getQueryTable*(req: var Request): TableRef[string, string] {.inline.} =
  ## Retrieve query parameters as a table
  result = req.getQuery()

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
  ## Defines a new controller procedure with the given name and body.
  ## The generated procedure is marked as `gcsafe` to allow it to be
  ## called from a GC-safe context.
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
  ## An alias for `newController` macro to define controller handlers
  newController(name, body)

macro go*(id: untyped, params: typed) =
  ## Redirects to a specific GET route using the controller identifier.
  ## This macro adds support for redirecting with query parameters.
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
  ## Redirects to a specific GET route using the controller identifier. 
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
  var authorized = false
  withDBPool do:
    let ssid {.inject.} = req.getClientId()
    if not ssid.isNone:
      let anySessions =
        Models.table(UserSessions).selectAll()
          .where("session_id", ssid.get()).getAll()
      authorized = not anySessions.isEmpty()
    else:
      authorized = false
  authorized

#
# Paths
#
template storage*(path: string): string =
  resolve(appInstance().applicationPaths, "storage", path)