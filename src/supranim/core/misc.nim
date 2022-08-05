from std/os import `/../`, getCacheDir
from std/macros import getProjectPath

let baseCachePath* {.compileTime.} = getProjectPath() /../ ".cache"

proc getProjectCachePath*(file = ""): string {.compileTime.} =
    result = baseCachePath
    if file.len != 0:
        result &= "/" & file