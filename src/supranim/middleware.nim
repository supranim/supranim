# Supranim - a modular web framework 
# for building web apps & microservices in Nim.
#
# (c) 2024 Made by Humans from OpenPeeps | MIT License
#     Check Docs: https://supranim.com
#     Check GitHub: https://github.com/supranim

import std/[options, macros, macrocache]
export options

from std/httpcore import HttpCode,
    Http200, Http204, Http301, Http302,
    Http403, Http404, Http500, Http501

export HttpCode, Http200, Http204, Http301,
    Http302, Http403, Http404, Http500, Http501

import ./core/[request, response]
from ./core/http import resp

export request, response, resp

from ./core/http/router import baseMiddlewares

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
        newIdentDefs(ident "req", ident "Request"),
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
    body = body,
    pragmas = nnkPragma.newTree(ident"nimcall")
  )

template next*(status: HttpCode = Http204): typed =
  return status

template fail*(status: HttpCode = Http403): typed =
  return status

template abort*(target: string = "/"): typed =
  assert target.len > 0
  res.setCode(Http302)
  res.addHeader("location", target)
  return Http302