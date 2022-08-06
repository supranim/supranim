# Supranim is a simple MVC-style web framework for building
# fast web applications, REST API microservices and other cool things.
#
# (c) 2021 Supranim is released under MIT License
#          Made by Humans from OpenPeep
#          https://supranim.com | https://github.com/supranim

# Include-only file

from std/strutils import join, indent

let tkImport {.compileTime.} = "import"
let tkExport {.compileTime.} = "export"

type 
    Runtime = object
        imports: seq[string]
        exports: seq[string]

proc add(runtime: var Runtime, id: string, canExport = false, isDefault = false) {.compileTime.} =
    if isDefault:
        runtime.imports.add("supranim/support/" & id)
    else:
        runtime.imports.add(id)
    if canExport:
        runtime.exports.add(id)

proc getCode*(runtime: var Runtime): string {.compileTime.} =
    result = tkImport & indent(runtime.imports.join(",\n      "), 1)
    result &= "\n"
    result &= tkExport & indent(runtime.exports.join(",\n      "), 1)