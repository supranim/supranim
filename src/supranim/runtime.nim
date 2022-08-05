import supranim/core/misc
from std/os import `/`, dirExists
import std/macros

macro init() =
    result = newStmtList()
    if not dirExists baseCachePath:
        discard staticExec("mkdir " & baseCachePath)
    result.add(
        nnkIncludeStmt.newTree(
            ident(getProjectCachePath("runtime.nim"))
        )
    )

init()