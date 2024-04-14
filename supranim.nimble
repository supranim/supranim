# Package

version       = "0.1.3"
author        = "George Lemon"
description   = "A fast web framework for Nim development"
license       = "MIT"
srcDir        = "src"
bin           = @["supranim"]
binDir        = "bin"
installExt    = @["nim"]

# Core dependencies
requires "nim >= 2.0.0"
requires "mummy"
requires "httpbeast#head"
requires "zmq", "ws"
requires "flatty"
requires "ioselectors"
requires "supersnappy"
requires "libsodium"
requires "jsony"
requires "nyml#head"
requires "https://github.com/supranim/enimsql"
# requires "enimsql"
requires "msgpack4nim"

# Supranim packages
requires "emitter"
requires "find"

# CLI dependencies
requires "kapsis#head"

task cli, "Build Supranim's CLI":
  exec "nimble build"
