#
# Supranim is a full-featured web framework for building
# web apps & microservices in Nim.
# 
#   (c) 2025 MIT License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#

import std/[options, macros, macrocache]
export options

from std/httpcore import HttpCode,
    Http200, Http204, Http301, Http302,
    Http403, Http404, Http500, Http501

export HttpCode, Http200, Http204, Http301,
    Http302, Http403, Http404, Http500, Http501

import ./http/[request, response]
export request, response

macro newAfterware*(name, body: untyped) =
  ## A macro that generates a new afterware procedure
  ## to run after a request has been made
  result = newStmtList()
  add result, newProc(
    name = nnkPostfix.newTree(ident"*", name),
    params = [
      ident "HttpCode",
      newIdentDefs(ident"req", nnkVarTy.newTree(ident"Request")),
      newIdentDefs(ident"res", nnkVarTy.newTree(ident"Response"))
    ],
    body = body
  )
