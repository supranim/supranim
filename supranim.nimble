# Package

version       = "0.1.3"
author        = "George Lemon"
description   = "A fast web framework for Nim development"
license       = "MIT"
srcDir        = "src"
# bin           = @["supra"]
# binDir        = "bin"
# installExt    = @["nim"]

# Core dependencies
requires "nim >= 2.0.0"
requires "mummy"
requires "httpbeast#head"
requires "zmq", "ws"
requires "dotenv >= 2.0.1"
requires "flatty"
requires "ioselectors"
requires "supersnappy"
requires "libsodium"
requires "jsony"
requires "enimsql"

# Supranim packages
requires "emitter"
requires "find"

# CLI dependencies
requires "kapsis"

task cli, "Build Supranim's CLI":
  exec "nimble build"