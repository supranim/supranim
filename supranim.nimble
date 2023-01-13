# Package

version       = "0.1.0"
author        = "George Lemon"
description   = "A fast Hyper Server & Web Framework"
license       = "MIT"
srcDir        = "src"

# Dependencies
requires "nim >= 1.4.8"
requires "nimcrypto"
requires "jsony"
requires "nyml"
requires "filetype"
requires "pkginfo"

task docgen, "Generate API documentation":
  exec "nim doc --project --index:on --outdir:htmldocs src/supranim.nim"

task devrouter, "Build router for testing purpose":
  exec "nim c -r src/supranim/core/router.nim"