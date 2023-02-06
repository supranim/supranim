from supranim/core/application import dirCachePath
from std/os import `/`, dirExists
import std/macros

macro initFacades() =
    result = newStmtList()
    result.add(
        nnkIncludeStmt.newTree(
            ident(dirCachePath / "facade.nim")
        )
    )

initFacades()