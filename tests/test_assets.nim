#
# Unit tests for supranim/service/assets
#
import std/unittest
import std/[tables, strutils]

import supranim/service/assets

suite "Assets":
  test "staticAssets returns a singleton instance":
    check staticAssets() == staticAssets()
    check staticAssets() != nil

  test "addAsset/get/hasAsset for binary assets":
    let sta = staticAssets()
    sta.addAsset("css/app.css", @[1'u8, 2, 3])
    check sta.hasAsset("css/app.css")
    check sta.get("css/app.css") == @[1'u8, 2, 3]

  test "get of a missing asset raises StaticAssetsError":
    let sta = staticAssets()
    expect StaticAssetsError:
      discard sta.get("missing/asset")

  test "addAsset with a duplicate key raises StaticAssetsError":
    let sta = staticAssets()
    sta.addAsset("dup.bin", @[1'u8])
    expect StaticAssetsError:
      sta.addAsset("dup.bin", @[2'u8])

  test "addTextFile/directory/getFile/hasFile":
    let sta = staticAssets()
    sta.addTextFile("assets", "index.html", "<html/>")
    let dir = sta.directory("assets")
    check dir.hasFile("index.html")
    check dir.getFile("index.html") == "<html/>"

  test "directory of an unknown dir raises StaticAssetsError":
    let sta = staticAssets()
    expect StaticAssetsError:
      discard sta.directory("unknown")

  test "listAssetsDir filters by prefix":
    let sta = staticAssets()
    sta.addAsset("img/logo.png", @[1'u8])
    sta.addTextFile("assets", "img/icon.svg", "<svg/>")
    let list = sta.listAssetsDir("img/")
    check "img/logo.png" in list
    check "img/icon.svg" in list
    check list.len == 2

  test "isPlainText detects binary data":
    check isPlainText("hello world".toOpenArrayByte(0, 10)) == true
    check isPlainText([104'u8, 101, 108, 108, 111]) == true
    # NUL byte implies binary
    check isPlainText([0'u8, 1, 2, 3]) == false
