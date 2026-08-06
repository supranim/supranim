# Package

version       = "0.1.7"
author        = "OpenPeeps"
description   = "A full-featured web framework for Nim"
license       = "LGPL-3.0-or-later"
srcDir        = "src"

# Core dependencies
requires "nim >= 2.2.10"
requires "semver >= 1.2.3"
requires "kapsis >= 0.3.4"

feature "powpow":
  requires "powpow >= 0.1.4"
  requires "emitter[powpow]"

feature "libevent":
  requires "libevent >= 0.1.2"

requires "flatty >= 0.4.0"
requires "openparser >= 0.1.2"
requires "emitter >= 0.1.0"
requires "ozark >= 0.1.5"
requires "threading >= 0.1.0"
requires "mimedb >= 0.1.0"
requires "checksums >= 0.2.2"
