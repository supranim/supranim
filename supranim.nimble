# Package

version       = "0.1.0"
author        = "Supranim"
description   = "A fast Hyper Server & Web Framework"
license       = "MIT"
srcDir        = "src"

# Dependencies
requires "nim >= 1.4.8"
requires "pkginfo"
requires "nimcrypto"
requires "filetype"
requires "jsony"
requires "nyml"
# requires "valido"
# requires "find"

task docgen, "Generate API documentation":
  exec "nim doc --project --index:on --outdir:htmldocs src/supranim.nim"

task devrouter, "Build router for testing purpose":
  exec "nim c -r src/supranim/core/router.nim"