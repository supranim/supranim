#
# Unit tests for supranim/support/ws (rooms hub + session middleware)
#
import std/unittest
import std/[httpcore, tables, times]

import supranim/support/ws
import supranim/support/session as sessionStore
import supranim/core/request
import supranim/core/response

proc fakeWs(): WsConnection =
  ## Bare connection (nil transport): powpow's `sendSafe` treats it as
  ## a safe no-op, so hub logic is testable without a network.
  WsConnection()

proc reqWithCookie(cookie: string): Request =
  var headers = newHttpHeaders()
  if cookie.len > 0:
    headers.add("cookie", cookie)
  Request(headersFetched: true, headersCache: headers,
    routeParams: initTable[string, string]())

proc newRes(): Response =
  Response(headers: newHttpHeaders())

suite "support/ws hub":
  test "joinRoom is idempotent, roomCount tracks members":
    let hub = newWsHub()
    let a = fakeWs()
    let b = fakeWs()
    check hub.roomCount("lobby") == 0
    hub.joinRoom("lobby", a)
    hub.joinRoom("lobby", a)
    check hub.roomCount("lobby") == 1
    hub.joinRoom("lobby", b)
    check hub.roomCount("lobby") == 2

  test "nil connections are ignored":
    let hub = newWsHub()
    hub.joinRoom("lobby", nil)
    check hub.roomCount("lobby") == 0
    check hub.roomPeers("lobby").len == 0

  test "leaveRoom drops empty rooms":
    let hub = newWsHub()
    let a = fakeWs()
    hub.joinRoom("lobby", a)
    check hub.rooms() == @["lobby"]
    hub.leaveRoom("lobby", a)
    check hub.roomCount("lobby") == 0
    check hub.rooms().len == 0
    hub.leaveRoom("missing", a) # no-op

  test "leaveAllRooms removes from every room":
    let hub = newWsHub()
    let a = fakeWs()
    let b = fakeWs()
    hub.joinRoom("one", a)
    hub.joinRoom("two", a)
    hub.joinRoom("two", b)
    hub.leaveAllRooms(a)
    check hub.roomCount("one") == 0
    check hub.roomCount("two") == 1
    check hub.memberRooms(a).len == 0
    check hub.memberRooms(b) == @["two"]

  test "roomPeers honors exclude":
    let hub = newWsHub()
    let a = fakeWs()
    let b = fakeWs()
    hub.joinRoom("lobby", a)
    hub.joinRoom("lobby", b)
    check hub.roomPeers("lobby").len == 2
    check hub.roomPeers("lobby", exclude = a).len == 1
    check hub.roomPeers("missing").len == 0

  test "broadcast to missing/closed rooms is a safe no-op":
    let hub = newWsHub()
    hub.broadcast("missing", "hello") # must not raise
    let a = fakeWs() # nil transport: sendSafe no-ops
    hub.joinRoom("lobby", a)
    hub.broadcast("lobby", "hello")
    hub.broadcast("lobby", "hello", exclude = a)

  test "defaultHub is a stable singleton":
    check defaultHub() == defaultHub()
    setDefaultHub(newWsHub())
    check defaultHub().rooms().len == 0

suite "support/ws auth":
  test "requireWsSession allows valid sessions, rejects others":
    setDefaultHub(newWsHub()) # isolate (hub unused here, keeps state fresh)
    let store = sessionStore.defaultStoreInit()
    let s = store.createSession()
    var res = newRes()
    var okReq = reqWithCookie("ssid=" & s.id)
    check requireWsSession(okReq, res) == Http204
    var badReq = reqWithCookie("ssid=does-not-exist")
    check requireWsSession(badReq, res) == Http403
    var noCookie = reqWithCookie("")
    check requireWsSession(noCookie, res) == Http403
    # expired sessions are rejected
    s.created = s.created - initDuration(hours = 1000)
    var staleReq = reqWithCookie("ssid=" & s.id)
    check requireWsSession(staleReq, res) == Http403
