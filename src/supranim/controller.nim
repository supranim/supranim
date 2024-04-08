# Supranim is a simple MVC web framework
# for building web apps & microservices in Nim.
#
# (c) 2024 MIT License | Made by Humans from OpenPeeps
# https://supranim.com | https://github.com/supranim

import std/[macros, macrocache, asyncdispatch, strutils,
  tables, httpcore, uri, sequtils, options]

import ./core/[request, response, router]
import ./support/cookie

import ./application except init, initSystemServices, configs
export application

export request, response
export asyncdispatch, options

import pkg/libsodium/[sodium, sodium_sizes]
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

proc getFieldsTable*(req: Request): Table[string, string] =
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
  # case body[0].kind
  # of nnkCommentStmt:
    # ctrlDescription[name.strVal] = body[0]
  # else: discard
  result =
    newProc(
      name = nnkPostfix.newTree(ident("*"), name),
      params = [
        ident("Response"),
        newIdentDefs(
          ident("req"),
          ident("Request"),
          newEmptyNode()
        ),
        newIdentDefs(
          ident("res"),
          nnkVarTy.newTree(ident("Response")),
          newEmptyNode()
        ),
        newIdentDefs(
          ident("app"),
          ident("Application"),
          newEmptyNode()
        ),
      ],
      body =
        nnkPragmaBlock.newTree(
          nnkPragma.newTree(ident("gcsafe")),
          body
        )
    )

template ctrl*(name, body: untyped) =
  newController(name, body)

macro go*(id: untyped) =
  if queuedRoutes.hasKey(id.strVal):
    let routeRegistrar = queuedRoutes[id.strVal]
    let methodType = routeRegistrar[3]
    if methodType.eqIdent("HttpGet"):
      result = newStmtList()
      add result, newCall(ident("redirect"), routeRegistrar[2])
    else: discard # todo compile-time error

template isAuth*(): bool =
  (
    let ssid = req.getClientId
    if not ssid.isNone:
      let status = session.cmd(sessionCheck, [ssid.get()])
      status.isSome()
    else:
      false
  )
