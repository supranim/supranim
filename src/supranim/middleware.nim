# Supranim is a simple MVC web framework
# for building web apps & microservices in Nim.
#
# (c) 2024 MIT License | Made by Humans from OpenPeeps
# https://supranim.com | https://github.com/supranim

import std/[options, macros]
export options

from std/httpcore import HttpCode,
    Http200, Http301, Http403, Http404,
    Http500, Http501

export HttpCode, Http200, Http301,
    Http403, Http404, Http500, Http501

import ./core/[request, response]
export request, response

from ./core/router import next, fail, abort
export next, fail, abort

from ./controller import getClientId, getClientCookie
export getClientId, getClientCookie

macro newMiddleware*(name, body: untyped) =
  ## Macro for creating a new middleware proc
  result = newStmtList()
  add result, newProc(
    name = nnkPostfix.newTree(ident("*"), name),
    params = [
      ident "HttpCode",
      newIdentDefs(ident "req", ident "Request"),
      newIdentDefs(ident "res", nnkVarTy.newTree(ident "Response"))
    ],
    body = body
  )

#
# Response High-level API
#
# proc setCookie*(res: var Response, cookie: ref Cookie) =
#   ## Add a new `Cookie` to `Response` instance.
#   res.addHeader("set-cookie", $(cookie))
