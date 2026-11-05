#
# Supranim is a high-performance web framework for building
# web applications and microservices in Nim
# 
#   (c) 2026 LGPL-v3-or-later License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#

import std/[macros, macrocache, asyncdispatch, strutils,
          tables, uri, sequtils, options]

import std/httpcore except HttpMethod
import pkg/openparser/json
import ./core/[request, response, router, fileserver]
import ./support/cookie
import ./support/session as coreSessionStore

from ./core/application import appInstance
from ./network/webserver import streamFile

export json except json

export uri, request, response, tables,
        asyncdispatch, options, streamFile
export fileserver, getQuery, Http200, Http201,
        Http400, Http404, Http500, Http502, HttpCode

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

proc getFieldsJson*(req: var Request): JsonNode =
  ## Parses the request body as JSON. Returns `nil` when the body
  ## is missing or invalid (never raises).
  let body = req.getBody().get("")
  if body.len == 0: return nil
  try:
    result = json.fromJson(body)
  except json.OpenParserJsonError:
    result = nil
  except CatchableError:
    result = nil

proc getSomeBodyData*(req: var Request): SomeBodyData =
  ## Returns the body fields from `Request`.
  ## When called for the first time it will decode the body
  ## and store the result in `BodyData` table.
  ##
  ## If `BodyData` is already set, it will return the
  ## existing table.
  var res = BodyData()
  for x in req.getBody().get("").decodeQuery:
    res[x[0]] = x[1]
  some(res)

proc getBodyDataJson*(req: var Request): SomeBodyData =
  ## Returns JSON body fields as a string table.
  ## Only meaningful when the body is a JSON object; other shapes
  ## and invalid JSON yield `none` (never raises).
  ##
  ## Note this must be called only when the provided body is JSON.
  ## Invalid JSON will be rejected and the returned value
  ## will be `none`.
  let body = req.getBody().get("")
  if body.len == 0: return none(BodyData)
  try:
    let node = json.fromJson(body)
    if node.isNil or node.kind != JObject:
      return none(BodyData)
    var res = BodyData()
    for k, v in node:
      case v.kind
      of JString: res[k] = v.getStr()
      of JInt: res[k] = $v.getInt()
      of JFloat: res[k] = $v.getFloat()
      of JBool: res[k] = $v.getBool()
      of JNull: res[k] = ""
      else: res[k] = $v
    return some(res)
  except json.OpenParserJsonError:
    return none(BodyData)
  except CatchableError:
    return none(BodyData)

proc getFieldsTable*(req: var Request): SomeBodyData {.inline.} =
  ## An alias of `getSomeBodyData`
  req.getSomeBodyData()

proc getFieldsTableJson*(req: var Request): SomeBodyData {.inline.} =
  ## An alias of `getBodyDataJson`
  req.getBodyDataJson()

proc getBodyData*[T: BodyData|JsonNode](req: var Request, dataType: typedesc[T]): Option[T] =
  ## Returns the body data from `Request` as `JsonNode`
  when T is BodyData:
    result = req.getSomeBodyData()
  elif T is JsonNode:
    let body = req.getBody().get("")
    if body.len == 0: return none(JsonNode)
    try:
      return some(json.fromJson(body))
    except json.OpenParserJsonError:
      return none(JsonNode)
    except CatchableError:
      return none(JsonNode)

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

proc getSessionCookie*(req: var Request): Option[Cookie] =
  ## Returns the client-side `ssid` Cookie from `Request`
  if req.hasCookies:
    var clientCookies: CookiesTable = parseCookies(req.getCookies().get())
    if clientCookies.hasKey("ssid"):
      return some(clientCookies["ssid"])

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
  ## Returns true when the request carries a valid, non-expired
  ## session from the core in-memory store (`support/session`).
  ##
  ## Previously this template required `withDBPool` + `Models.table(UserSessions)`
  ## in scope (provided by `supranim-session`/ozark) and failed to compile
  ## in plain core apps. DB-backed authentication now lives in
  ## `supranim-session` (`isAuthenticated`, `withDBUserSession`); this core
  ## check is cookie + in-memory store only. For persistent users, call
  ## `session.getSessionFromRequest(req)` then verify against your DB.
  var isAuthResult = false
  block:
    try:
      let ssidOpt = req.getClientId()
      if ssidOpt.isSome:
        isAuthResult = coreSessionStore.defaultStoreInit().hasSession(ssidOpt.get())
    except CatchableError:
      discard
  isAuthResult

#
# Paths
#
template storage*(path: string): string =
  resolve(appInstance().applicationPaths, "storage", path)