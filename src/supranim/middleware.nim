# Supranim is a simple MVC web framework
# for building web apps & microservices in Nim.
#
# (c) 2024 MIT License | Made by Humans from OpenPeeps
# https://supranim.com | https://github.com/supranim

import std/[options, macros, macrocache]
export options

from std/httpcore import HttpCode,
    Http200, Http301, Http403, Http404,
    Http500, Http501

export HttpCode, Http200, Http301,
    Http403, Http404, Http500, Http501

import ./core/[request, response]
from ./core/http import resp

export request, response, resp

from ./core/router import next, fail, abort, baseMiddlewares
export next, fail, abort

from ./controller import getClientId, getClientCookie
export getClientId, getClientCookie

macro newBaseMiddleware*(name: untyped, body: untyped) =
  ## A macro that generates new middleware procedure
  ## to run at every `onRequest`. A good example would be
  ## `middleware/fixUriSlash.nim` and `middleware/i18n.nim`
  result = newStmtList()
  baseMiddlewares[name.strVal] = newEmptyNode()
  add result,
    newProc(
      name = nnkPostfix.newTree(ident("*"), name),
      params = [
        ident "HttpCode",
        newIdentDefs(ident "req", nnkVarTy.newTree(ident "Request")),
        newIdentDefs(ident "res", nnkVarTy.newTree(ident "Response"))
      ],
      body = body
    )

macro newMiddleware*(name, body: untyped) =
  ## A macro that generates new middleware procedure
  ## to run when a route `Router.checkExists`
  ## returns true
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
