#
# Unit tests for supranim/network/webserver (powpow backend)
#
import std/unittest
import std/[options, net]

import supranim/network/webserver

proc lowLevelCb(req: pointer, arg: pointer) {.cdecl, gcsafe.} =
  discard

suite "WebServer (powpow backend)":
  test "newWebServer defaults to port 8080, single-threaded":
    let server = newWebServer()
    check server.port == Port(8080)
    check server.enableMultiThreading == false

  test "newWebServer honors port and threading flag":
    let server = newWebServer(Port(9090), true)
    check server.port == Port(9090)
    check server.enableMultiThreading == true

  test "parseRangeHeader parses inclusive ranges":
    check parseRangeHeader("bytes=0-99", 1000) == some((0, 99))
    check parseRangeHeader("bytes=200-300", 1000) == some((200, 300))

  test "parseRangeHeader parses open-ended ranges":
    check parseRangeHeader("bytes=100-", 1000) == some((100, 999))

  test "parseRangeHeader rejects invalid ranges":
    # suffix ranges are not supported
    check parseRangeHeader("bytes=-200", 1000).isNone
    # end beyond file size
    check parseRangeHeader("bytes=0-9999", 1000).isNone
    # end equals file size (must be strictly less)
    check parseRangeHeader("bytes=0-1000", 1000).isNone
    # start beyond file size
    check parseRangeHeader("bytes=1000-", 1000).isNone
    # inverted range
    check parseRangeHeader("bytes=100-50", 1000).isNone
    # wrong unit
    check parseRangeHeader("items=0-10", 1000).isNone
    # malformed
    check parseRangeHeader("bytes=abc", 1000).isNone
    check parseRangeHeader("", 1000).isNone

  test "addCallback and registerCallback normalize the path":
    var server = newWebServer()
    server.addCallback("/foo", lowLevelCb)
    server.addCallback("/foo/", lowLevelCb) # trailing slash normalized away
    server.registerCallback("/bar", lowLevelCb)
    server.registerCallback("/bar", lowLevelCb) # idempotent

  test "unregisterCallback is safe for unknown paths":
    var server = newWebServer()
    server.unregisterCallback("/never-registered")
    server.registerCallback("/x", lowLevelCb)
    server.unregisterCallback("/x")
    server.unregisterCallback("/x")
