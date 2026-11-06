#
# Supranim is a high-performance web framework for building
# web applications and microservices in Nim
#
#   (c) 2026 LGPL-v3-or-later License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#

## WebSocket rooms, broadcast and upgrade helpers for Supranim core.
##
## `network/websocket` is a thin re-export over powpow. This module adds
## the framework layer that was missing: named rooms (pub-sub) on a
## thread-safe hub, an authenticated-upgrade helper, and a
## session-aware middleware for `router.ws` routes.
##
## Typical route (session cookie checked by middleware, upgrade in handler):
##
## .. code-block:: nim
##   import supranim/support/ws
##
##   router.ws("/chat/{room:slug}", chatHandler,
##     middlewares = @[requireWsSession])
##
##   proc chatHandler(req: var Request, res: var Response) {.nimcall, gcsafe.} =
##     let room = req.params.getOrDefault("room", "lobby")
##     discard req.upgradeWs(res,
##       onOpen = proc(ws: WsConnection) =
##         defaultHub().joinRoom(room, ws),
##       onMessage = proc(ws: WsConnection, kind: WsFrameKind,
##                        data: openArray[byte]) =
##         if kind == wsText:
##           defaultHub().broadcast(room, cast[string](@data), exclude = ws),
##       onClose = proc(ws: WsConnection, code: int, reason: string) =
##         defaultHub().leaveAllRooms(ws))
##
## Standalone `WebService` apps keep using `ws do:` with `wss.onOpen/...`
## (see `examples/services_ws.nim`); the hub works there too.
##
## Thread safety: rooms are guarded by `pkg/threading/rwlock`. `broadcast`
## copies the member list under a read lock and sends outside it —
## powpow's `sendText` is thread-safe (cross-thread writes are deferred
## to the loop thread), and closed/nil connections are skipped by powpow.

import std/[tables, locks, options]
from std/httpcore import HttpCode, Http204, Http403

import pkg/threading/rwlock

import ../network/websocket
export websocket

import ../core/request
import ../core/response
import ./session as sessionStore

type
  WsHub* = ref object
    ## Named-room registry: `room name -> (conn pointer -> connection)`.
    rooms: Table[string, Table[pointer, WsConnection]]
    lock: RwLock

proc newWsHub*(): WsHub =
  ## Creates an empty hub (no global state, useful in tests).
  WsHub(rooms: initTable[string, Table[pointer, WsConnection]](),
    lock: createRwLock())

var defaultWsHub {.global.}: WsHub
var defaultWsHubLock {.global.}: Lock
initLock(defaultWsHubLock)

proc defaultHub*(): WsHub {.gcsafe.} =
  ## Returns the process-global hub, creating it on first use.
  ## Lock-guarded; the `gcsafe` block asserts manual safety for the
  ## shared global (same pattern as `session.defaultStoreInit`).
  {.gcsafe.}:
    withLock(defaultWsHubLock):
      if defaultWsHub.isNil:
        defaultWsHub = newWsHub()
      result = defaultWsHub

proc setDefaultHub*(hub: WsHub) {.gcsafe.} =
  ## Replaces the process-global hub (useful in tests).
  {.gcsafe.}:
    withLock(defaultWsHubLock):
      defaultWsHub = hub

proc joinRoom*(hub: WsHub, room: string, ws: WsConnection) =
  ## Adds `ws` to `room` (creates the room on first join). Idempotent.
  if ws.isNil: return
  writeWith(hub.lock):
    if not hub.rooms.hasKey(room):
      hub.rooms[room] = initTable[pointer, WsConnection]()
    hub.rooms[room][cast[pointer](ws)] = ws

proc leaveRoom*(hub: WsHub, room: string, ws: WsConnection) =
  ## Removes `ws` from `room`. Empty rooms are dropped. No-op when missing.
  if ws.isNil: return
  writeWith(hub.lock):
    if hub.rooms.hasKey(room):
      hub.rooms[room].del(cast[pointer](ws))
      if hub.rooms[room].len == 0:
        hub.rooms.del(room)

proc leaveAllRooms*(hub: WsHub, ws: WsConnection) =
  ## Removes `ws` from every room. Call from `onClose`.
  ## Empty rooms are dropped.
  if ws.isNil: return
  let key = cast[pointer](ws)
  writeWith(hub.lock):
    var emptyRooms: seq[string]
    for room, members in hub.rooms.mpairs:
      members.del(key)
      if members.len == 0:
        emptyRooms.add(room)
    for room in emptyRooms:
      hub.rooms.del(room)

proc roomPeers*(hub: WsHub, room: string,
    exclude: WsConnection = nil): seq[WsConnection] =
  ## Returns the current members of `room`, minus `exclude`.
  ## Pure selection logic (no sending) so it is unit-testable.
  readWith(hub.lock):
    if hub.rooms.hasKey(room):
      for key, conn in hub.rooms[room]:
        if not conn.isNil and conn != exclude:
          result.add(conn)

proc broadcast*(hub: WsHub, room: string, msg: string,
    exclude: WsConnection = nil) =
  ## Sends `msg` to every member of `room` except `exclude`.
  ## Missing rooms and closed connections are safe no-ops
  ## (powpow skips non-connected sockets internally).
  let peers = hub.roomPeers(room, exclude)
  for conn in peers:
    conn.sendText(msg)

proc roomCount*(hub: WsHub, room: string): int =
  ## Number of members currently in `room` (0 when missing).
  readWith(hub.lock):
    if hub.rooms.hasKey(room):
      result = hub.rooms[room].len

proc rooms*(hub: WsHub): seq[string] =
  ## Names of all non-empty rooms.
  readWith(hub.lock):
    for room in hub.rooms.keys:
      result.add(room)

proc memberRooms*(hub: WsHub, ws: WsConnection): seq[string] =
  ## Names of all rooms containing `ws`.
  if ws.isNil: return
  let key = cast[pointer](ws)
  readWith(hub.lock):
    for room, members in hub.rooms:
      if members.hasKey(key):
        result.add(room)

# Auth + upgrade

proc requireWsSession*(req: var Request, res: var Response): HttpCode {.nimcall.} =
  ## `router.ws` middleware: only lets the upgrade proceed when the
  ## request carries a valid, non-expired session from the core
  ## in-memory store (`support/session`). Returns `Http204` to continue,
  ## `Http403` otherwise (the WS branch in `supranim.nim` answers `403`).
  ## For DB-backed users, write a similar middleware around
  ## `supranim-session`'s `isAuthenticated`.
  let ssid =
    try:
      req.getSessionIdFromRequest(sessionStore.defaultStoreInit())
    except CatchableError:
      none(string)
  if ssid.isSome and sessionStore.defaultStoreInit().hasSession(ssid.get()):
    return Http204
  Http403

proc upgradeWs*(req: var Request, res: var Response,
    onOpen: WsOpenCb = nil,
    onMessage: WsMessageCb = nil,
    onClose: WsCloseCb = nil,
    onError: WsErrorCb = nil,
    protocols: openArray[string] = [],
    maxFrameSize = 10 * 1024 * 1024): WsConnection =
  ## Upgrades a `router.ws` route to WebSocket. Thin wrapper over
  ## powpow's `websocketUpgrade` using the request's raw handles,
  ## then marks the supranim response sent so the WS branch in
  ## `supranim.nim` returns without writing an HTTP body.
  ## Returns `nil` when the client missed the WebSocket headers
  ## (powpow already answered `400` on the raw response).
  result = websocketUpgrade(req.powRes, req.powReq, nil,
    onOpen, onMessage, onClose, onError, maxFrameSize, protocols)
  req.responseSent = true
