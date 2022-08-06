from supranim/core/application import baseCachePath
from std/os import `/`, dirExists
import std/macros

macro initRuntime() =
    result = newStmtList()
    result.add(
        nnkIncludeStmt.newTree(
            ident(baseCachePath / "runtime.nim")
        )
    )

initRuntime()