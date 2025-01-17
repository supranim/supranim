# Supranim is a simple MVC web framework
# for building web apps & microservices in Nim.
#
# (c) 2024 MIT License | Made by Humans from OpenPeeps
# https://supranim.com | https://github.com/supranim

import std/[macros, os]
import ./core/paths

macro initRuntime() =
  result = newStmtList()
  add result,
    nnkImportStmt.newTree(
      ident(cachePath / "runtime.nim")
    ),
    nnkExportStmt.newTree(
      ident("runtime")
    )

initRuntime()