# Supranim is a simple MVC web framework
# for building web apps & microservices in Nim.
#
# (c) 2024 MIT License | Made by Humans from OpenPeeps
# https://supranim.com | https://github.com/supranim

import pkg/[zmq, filetype]
import std/[os, strutils, tables, options]

type
  AssetsCommand* = enum
    addAsset = "add.asset"
    getAsset = "get.asset"

when isMainModule:
  # Setup the standalone Service Provider - Assets Manager
  import pkg/watchout
  import pkg/libsodium/[sodium, sodium_sizes]
  from ../application import basePath
  type
    File = object
      alias, path: string
      fileType: string

    AssetsManager = ref object
      keypair: tuple[pk, sk: string] # CryptoBoxPublicKey, CryptoBoxSecretKey
      source: string
      public: string
      files: TableRef[string, File]

  # Compile-time options
  const
    assetsSourcePath {.strdefine.} = "assets"
    assetsPublicPath {.strdefine.} = "public"

    supranimBasePath {.strdefine.} = ""
    supranimStoragePath {.strdefine.} = ""

  var Assets: AssetsManager

  proc init(assets: AssetsManager) =
    # Auto-discover available static assets inside of `assetsSourcePath`
    proc onChange(file: watchout.File) =
      echo "ok"

    proc onFound(file: watchout.File) =
      # echo file
      discard

    var watcher = newWatchout(@[supranimStoragePath / assetsSourcePath / "*"], onChange, onFound)
    watcher.start(true) # start watcher in a new thread
  init Assets

else:
  # Public API exposed to the main Supranim application
  type
    Asset* = object
      ftype: FileType

  proc assets*(name: string): Asset =
    ## Return contents of a static file `name`
