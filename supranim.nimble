# Package

version       = "0.1.0"
author        = "OpenPeeps"
description   = "A full-featured web framework for Nim"
license       = "MIT"
srcDir        = "src"

# Core dependencies
requires "nim >= 2.0.0"
requires "libsodium"
# requires "libdatachannel"
requires "libevent"
requires "cbor_serialization"
# requires "monocypher"

requires "flatty"
requires "jsony"

# github.com/openpeeps
requires "nyml#head"
requires "emitter"
requires "kapsis"

requires "semver"
requires "threading"

# requires "taskman"
# requires "https://github.com/supranim/enimsql"

requires "zip"
requires "mimedb#head"

# requires "otp >= 0.3.3"
# requires "qr"
# requires "quickjwt"

# CLI dependencies
# requires "kapsis#head"

task cli, "Build Supranim's CLI":
  exec "nimble compile -d:ssl --out:./bin/supra src/supranim.nim"