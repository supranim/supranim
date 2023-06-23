from supranim/core/application import dirCachePath
from std/os import `/`, dirExists
import std/macros

macro initRuntime() =
  result = newStmtList()
  result.add(
    nnkIncludeStmt.newTree(
      ident(dirCachePath / "runtime.nim")
    )
  )

initRuntime()