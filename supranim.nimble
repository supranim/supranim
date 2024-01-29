# Package

version       = "0.1.0"
author        = "George Lemon"
description   = "A super simple hyper framework written in Nim"
license       = "MIT"
srcDir        = "src"
bin           = @["supra"]
binDir        = "bin"
installExt    = @["nim"]

# Dependencies
requires "nim >= 2.0.0"
requires "httpbeast#head"
requires "zmq", "ws"
requires "dotenv >= 2.0.1"

requires "flatty"
requires "ioselectors"
requires "malebolgia"
requires "supersnappy"
requires "libsodium"
requires "jsony"

# cli dependencies
requires "kapsis"

# framework
requires "emitter"
requires "find"

# template engine

task cli, "Build Supranim's CLI":
  exec "nimble build"