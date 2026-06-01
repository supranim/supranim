# A simple publishing platform powered by Supranim,
# a modern web framework for Nim.
#
# (c) 2026 George Lemon | AGPLv3 License
#     Made by Humans from OpenPeeps
#     https://github.com/openpeeps/sunday

## This service provider wraps the `supranim/support/filesystem` module,
## providing a unified API for file storage operations. It allows you to  manage files across
## different storage backends (like local disk, cloud storage, etc.) using a consistent interface.

import std/[os, memfiles, strutils, tables, options, times]

import pkg/supranim/core/services
import pkg/supranim/core/[paths, application]

import pkg/supranim/support/filesystem
export filesystem

initService Filesystem[Singleton]:
  client do:
    # where we define the publici API for the Storage service
    proc storage*: Filesystem =
      ## Returns the singleton instance of the Filesystem service, which provides
      ## methods for file operations across different storage backends.
      getFilesystemInstance()[]

    proc init*(app: Application) =
      discard getFilesystemInstance(
        proc(instance: ptr Filesystem) =
          {.gcsafe.}:
            instance[] = newFilesystem()
      )

      # Root resolved at RUNTIME from config/env — binary-location-independent
      storage().addDisk("local", newLocalDriver(app.paths.resolve("storage")))
      storage().addDisk("themes", newLocalDriver(app.paths.resolve("themes")))

      # API
      # fs.write("uploads/avatar.png", pngBytes, visPublic)
      # let data = storage().disk("themes").read("twentysix/theme.yaml")
      # echo data