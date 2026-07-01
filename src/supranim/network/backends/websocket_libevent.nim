#
# Supranim is a high-performance web framework for building
# web applications and microservices in Nim
# 
#   (c) 2026 LGPL-v3-or-later License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#

import std/[tables, options, base64, sha1, strutils, sequtils]
import pkg/libevent/bindings/[event, http, bufferevent, buffer]

type
  WsOpenCb* = proc(ws: WsConnection) {.gcsafe.}
  WsMessageCb* = proc(ws: WsConnection, kind: WsFrameKind, data: openArray[byte]) {.gcsafe.}
  WsCloseCb* = proc(ws: WsConnection, code: int, reason: string) {.gcsafe.}
  WsErrorCb* = proc(ws: WsConnection, err: string) {.gcsafe.}

  WsFrameKind* = enum
    wsContinuation = 0x0
    wsText         = 0x1
    wsBinary       = 0x2
    wsClose        = 0x8
    wsPing         = 0x9
    wsPong         = 0xA

  WebSocketConnectionImpl = object
    id*: cint
    bev*: ptr bufferevent
    assembling: bool
    fragOpcode: int
    assembleBuf: seq[byte]
    onMessage*: WsMessageCb
    onClose*: WsCloseCb
    onError*: WsErrorCb
    onOpen*: WsOpenCb

  WsConnection* = ref WebSocketConnectionImpl

  WsSendJob = ref object
    bev: ptr bufferevent
    opcode: int
    payload: seq[byte]

const wsGuid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

var gConns: Table[ptr bufferevent, WsConnection]

proc writeFrame(bev: ptr bufferevent, opcode: int, payload: openArray[byte])
proc sendText*(ws: WsConnection, s: string)
proc sendBinary*(ws: WsConnection, data: openArray[byte])
proc sendPing*(ws: WsConnection, data: openArray[byte] = [])
proc sendPong*(ws: WsConnection, data: openArray[byte] = [])
proc closeWs*(ws: WsConnection, code: int = 1000, reason = "")
proc websocketUpgrade*(req: ptr evhttp_request,
                      onOpen: WsOpenCb = nil,
                      onMessage: WsMessageCb = nil,
                      onClose: WsCloseCb = nil,
                      onError: WsErrorCb = nil): WsConnection

# Backward-compat aliases
type
  WebSocketConnection* = WsConnection
  WebSocketFrameKind* = WsFrameKind
  OpenCb* = WsOpenCb
  MessageCb* = WsMessageCb
  CloseCb* = WsCloseCb
  ErrorCb* = WsErrorCb

proc cleanupWs(ws: WsConnection) =
  if ws.isNil: return
  if not ws.bev.isNil:
    if gConns.hasKey(ws.bev):
      gConns.del(ws.bev)

proc wsSendOnceCb(fd: evutil_socket_t, what: cshort, arg: pointer) {.cdecl.} =
  let job = cast[WsSendJob](arg)
  if not job.isNil and not job.bev.isNil:
    writeFrame(job.bev, job.opcode, job.payload)
  GC_unref(job)

proc sendFrameOnBase(c: WsConnection, opcode: int, payload: openArray[byte]) =
  if c.isNil or c.bev.isNil: return
  let base = bufferevent_get_base(c.bev)
  if base.isNil: return
  let job = WsSendJob(bev: c.bev, opcode: opcode, payload: @payload)
  GC_ref(job)
  var tv: Timeval
  tv.tv_sec = 0
  tv.tv_usec = 0
  discard event_base_once(base, -1, EV_TIMEOUT, wsSendOnceCb, cast[pointer](job), addr tv)

proc sendText*(ws: WsConnection, s: string) =
  if s.len == 0:
    sendFrameOnBase(ws, 0x1, @[])
  else:
    sendFrameOnBase(ws, 0x1, s.toOpenArrayByte(0, s.len-1))

proc sendBinary*(ws: WsConnection, data: openArray[byte]) =
  if data.len == 0:
    sendFrameOnBase(ws, 0x2, @[])
  else:
    sendFrameOnBase(ws, 0x2, data)

proc sendPing*(ws: WsConnection, data: openArray[byte] = []) =
  if data.len == 0:
    sendFrameOnBase(ws, 0x9, @[])
  else:
    sendFrameOnBase(ws, 0x9, data)

proc sendPong*(ws: WsConnection, data: openArray[byte] = []) =
  if data.len == 0:
    sendFrameOnBase(ws, 0xA, @[])
  else:
    sendFrameOnBase(ws, 0xA, data)

proc closeWs*(ws: WsConnection, code: int = 1000, reason = "") =
  var payload: seq[byte] = @[]
  if code != 0:
    payload.setLen(2 + reason.len)
    payload[0] = uint8((code shr 8) and 0xFF)
    payload[1] = uint8(code and 0xFF)
    for i, ch in reason: payload[2+i] = uint8(ch.ord and 0xFF)
  sendFrameOnBase(ws, 0x8, payload)

proc computeAccept(key: cstring): string =
  let digest = sha1.secureHash($key & wsGuid)
  let shaArray = cast[array[0 .. 19, uint8]](digest)
  result = base64.encode(shaArray)

proc writeFrame(bev: ptr bufferevent, opcode: int, payload: openArray[byte]) =
  if bev.isNil: return
  var hlen = 0
  var header: array[10, uint8]
  let n = payload.len
  hlen = 1
  header[0] = uint8(0x80 or (opcode and 0x0F))
  if n < 126:
    header[1] = uint8(n)
    hlen = 2
  elif n <= 0xFFFF:
    header[1] = 126
    header[2] = uint8((n shr 8) and 0xFF)
    header[3] = uint8(n and 0xFF)
    hlen = 4
  else:
    header[1] = 127
    var v = uint64(n)
    for i in 0 ..< 8:
      header[9 - i] = uint8(v and 0xFF)
      v = v shr 8
    hlen = 10
  let rcH = bufferevent_write(bev, addr header[0], csize_t(hlen))
  var rcP = 0
  if n > 0:
    rcP = bufferevent_write(bev, unsafeAddr payload[0], csize_t(n))
  discard bufferevent_flush(bev, EV_WRITE, BEV_FLUSH)

proc parseFrames(ws: WsConnection, inbuf: ptr Evbuffer) =
  while true:
    let avail = evbuffer_get_length(inbuf).int
    if avail < 2: break
    var p = evbuffer_pullup(inbuf, 2)
    if p.isNil: break
    let
      u = cast[ptr UncheckedArray[uint8]](p)
      b0 = u[0]
      b1 = u[1]
      fin = int((b0 shr 7) and 1)
      opcode = int(b0 and 0x0F)
      masked = int((b1 shr 7) and 1)
    var plen: uint64 = uint64(b1 and 0x7F)
    var header = 2
    if plen == 126'u64:
      if avail < header + 2: break
      discard evbuffer_pullup(inbuf, header + 2)
      let u2 = cast[ptr UncheckedArray[uint8]](evbuffer_pullup(inbuf, header + 2))
      plen = (uint64(u2[2]) shl 8) or uint64(u2[3])
      header += 2
    elif plen == 127'u64:
      if avail < header + 8: break
      discard evbuffer_pullup(inbuf, header + 8)
      let u8 = cast[ptr UncheckedArray[uint8]](evbuffer_pullup(inbuf, header + 8))
      var v: uint64 = 0
      for i in 0 ..< 8: v = (v shl 8) or uint64(u8[2 + i])
      plen = v
      header += 8
    var maskKey: array[4, uint8]
    if masked == 1:
      if avail < header + 4: break
      discard evbuffer_pullup(inbuf, header + 4)
      let m = cast[ptr UncheckedArray[uint8]](evbuffer_pullup(inbuf, header + 4))
      for i in 0 ..< 4: maskKey[i] = m[header + i]
      header += 4
    let need = header + int(plen)
    if avail < need: break
    let frame = cast[ptr UncheckedArray[uint8]](evbuffer_pullup(inbuf, need))
    var payload: seq[byte] = @[]
    if plen > 0:
      payload.setLen(int(plen))
      var off = header
      if masked == 1:
        for i in 0 ..< int(plen):
          payload[i] = frame[off + i] xor maskKey[i mod 4]
      else:
        for i in 0 ..< int(plen):
          payload[i] = frame[off + i]
    discard evbuffer_drain(inbuf, csize_t(need))
    let msgKind = WsFrameKind(opcode)
    case opcode
    of 0x0:
      if not ws.assembling:
        if not ws.onError.isNil: ws.onError(ws, "Unexpected continuation frame")
        ws.closeWs(1002, "Protocol error")
        return
      ws.assembleBuf.add payload
      if fin == 1:
        let finalKind = WsFrameKind(ws.fragOpcode)
        ws.assembling = false
        if not ws.onMessage.isNil: ws.onMessage(ws, finalKind, ws.assembleBuf)
        ws.assembleBuf.setLen(0)
    of 0x1, 0x2:
      if fin == 1:
        if not ws.onMessage.isNil: ws.onMessage(ws, msgKind, payload)
      else:
        ws.assembling = true
        ws.fragOpcode = opcode
        ws.assembleBuf.setLen(0)
        ws.assembleBuf.add payload
    of 0x8:
      ws.sendFrameOnBase(0x8, payload)
      if not ws.onClose.isNil:
        var code = 1000; var reason = ""
        if payload.len >= 2:
          code = (int(payload[0]) shl 8) or int(payload[1])
          if payload.len > 2:
            reason = cast[string](payload[2 ..^ 1])
        ws.onClose(ws, code, reason)
      return
    of 0x9:
      ws.sendFrameOnBase(0xA, payload)
    of 0xA:
      discard
    else:
      ws.closeWs(1003, "Unsupported opcode")
      return

proc bev_readcb(bev: ptr bufferevent, ctx: pointer) {.cdecl.} =
  let ws = cast[WsConnection](ctx)
  if ws.isNil: return
  let inbuf = bufferevent_get_input(bev)
  ws.parseFrames(inbuf)

proc bev_eventcb(bev: ptr bufferevent, what: cshort, ctx: pointer) {.cdecl.} =
  let ws = cast[WsConnection](ctx)
  if (what and BEV_EVENT_ERROR.cshort) != 0:
    if not ws.isNil and not ws.onError.isNil:
      ws.onError(ws, "bufferevent error")
  if (what and BEV_EVENT_EOF.cshort) != 0 or (what and BEV_EVENT_ERROR.cshort) != 0:
    if not ws.isNil and not ws.onClose.isNil:
      ws.onClose(ws, 1000, "")
    cleanupWs(ws)

proc evcon_closecb(conn: ptr evhttp_connection, arg: pointer) {.cdecl.} =
  let ws = cast[WsConnection](arg)
  if not ws.isNil and not ws.onClose.isNil:
    ws.onClose(ws, 1000, "")
  cleanupWs(ws)

proc websocketUpgrade*(req: ptr evhttp_request,
                      onOpen: WsOpenCb = nil,
                      onMessage: WsMessageCb = nil,
                      onClose: WsCloseCb = nil,
                      onError: WsErrorCb = nil): WsConnection =
  let inHeaders = evhttp_request_get_input_headers(req)
  if inHeaders.isNil:
    evhttp_send_reply(req, HTTP_BADREQUEST, "Bad Request", nil)
    return
  let skey = evhttp_find_header(inHeaders, "Sec-WebSocket-Key")
  if skey.isNil:
    evhttp_send_reply(req, HTTP_BADREQUEST, "Missing WebSocket Key", nil)
    return
  let outHeaders = evhttp_request_get_output_headers(req)
  discard evhttp_add_header(outHeaders, "Upgrade", "websocket")
  discard evhttp_add_header(outHeaders, "Connection", "Upgrade")
  let accept = computeAccept(skey)
  discard evhttp_add_header(outHeaders, "Sec-WebSocket-Accept", accept.cstring)
  evhttp_send_reply_start(req, 101, "Switching Protocols")
  let conn = evhttp_request_get_connection(req)
  if conn.isNil:
    evhttp_send_reply_end(req)
    return
  let bev = evhttp_connection_get_bufferevent(conn)
  if bev.isNil:
    evhttp_send_reply_end(req)
    return
  result = WsConnection(
    bev: cast[ptr bufferevent](bev),
    onMessage: onMessage,
    onClose: onClose,
    onError: onError,
    onOpen: onOpen
  )
  result.id = bufferevent_getfd(result.bev)
  gConns[result.bev] = result
  evhttp_send_reply_end(req)
  bufferevent_setcb(result.bev, bev_readcb, nil, bev_eventcb, cast[pointer](result))
  discard bufferevent_enable(result.bev, EV_READ or EV_WRITE)
  evhttp_connection_set_closecb(conn, evcon_closecb, cast[pointer](result))
  if not result.onOpen.isNil:
    result.onOpen(result)
  evhttp_send_reply_end(req)
