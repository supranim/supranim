# Package

version       = "0.1.0"
author        = "George Lemon"
description   = "A fast web framework for Nim development"
license       = "MIT"
srcDir        = "src"

# Core dependencies
requires "nim >= 2.0.0"

# web servers
requires "ioselectors"
requires "zmq"

requires "ws"
requires "netty"
requires "flatty"
requires "supersnappy"

requires "libsodium"

requires "jsony"

# github.com/openpeeps
requires "nyml#head"
requires "emitter"
requires "find"
requires "multipart"

requires "https://github.com/supranim/enimsql"
requires "threading"
requires "taskman"

# requires "otp >= 0.3.3"
# requires "qr"
# requires "quickjwt"

# CLI dependencies
# requires "kapsis#head"
# https://github.com/OpenSystemsLab/daemonize.nim/tree/master

task cli, "Build Supranim's CLI":
  exec "nimble build"

task test_autolink, "dev build autolink router":
  exec "nim c --out:./bin/autolink src/supranim/core/http/autolink.nim"
