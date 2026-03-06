# Package

version       = "0.1.0"
author        = "OpenPeeps"
description   = "A full-featured web framework for Nim"
license       = "MIT"
srcDir        = "src"
bin           = @["supra"]
binDir        = "bin" 

# Core dependencies
requires "nim >= 2.0.0"
requires "libsodium"
requires "libevent"
requires "flatty"
requires "jsony"
requires "nyml#head"
requires "emitter"
requires "kapsis#head"
requires "ozark"
requires "semver"
requires "threading"
requires "mimedb#head"

# requires "monocypher"
# requires "libdatachannel"
# requires "cbor_serialization"
# requires "taskman"
# requires "otp >= 0.3.3"
# requires "qr"
# requires "quickjwt"
