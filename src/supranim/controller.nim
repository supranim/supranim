# Supranim is a simple MVC web framework
# for building web apps & microservices in Nim.
#
# (c) 2024 MIT License | Made by Humans from OpenPeeps
# https://supranim.com | https://github.com/supranim

import std/[macros, asyncdispatch, strutils,
  tables, httpcore, uri, sequtils, options]

import ./core/[request, response, docs]
import ./support/cookie

export request, response
export asyncdispatch, options

#
# Request - High-level API
#
proc getBody*(req: Request): string =
  ## Retrieves `Request` body
  result = req.root.body().get()

proc getFields*(req: Request): seq[(string, string)] =
  ## Decodes `Request` body
  result = toSeq(req.root.body.get().decodeQuery)

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
  case body[0].kind
  of nnkCommentStmt:
    ctrlDescription[name.strVal] = body[0]
  else: discard
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
        )
      ],
      body =
        nnkPragmaBlock.newTree(
          nnkPragma.newTree(ident("gcsafe")),
          body
        )
    )

template ctrl*(name, body: untyped) =
  newController(name, body)

template isAuth*(): bool =
  (
    let ssid = req.getClientId
    if not ssid.isNone:
      let status = session.cmd(sessionCheck, [ssid.get()])
      status.isSome()
    else:
      false
  )
