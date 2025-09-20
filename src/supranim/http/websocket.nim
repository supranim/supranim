#
# Supranim is a full-featured web framework for building
# web apps & microservices in Nim.
# 
#   (c) 2025 MIT License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#

import std/[tables, options, base64, sha1, strutils, sequtils]
import pkg/libevent/bindings/[event, http, bufferevent, buffer]

type
  OpenCb* = proc (req: ptr WebSocketConnectionImpl) {.gcsafe.}
  MessageCb* = proc (conn: ptr WebSocketConnectionImpl, opcode: int, data: openArray[byte]) {.gcsafe.}
  CloseCb*   = proc (conn: ptr WebSocketConnectionImpl, code: int, reason: string) {.gcsafe.}
  ErrorCb*   = proc (conn: ptr WebSocketConnectionImpl, err: string) {.gcsafe.}

  WebSocketFrameKind* = enum
    wsNone
    wsText
    wsBinary
    wsClose
    wsPing
    wsPong

  WebSocketConnectionImpl* = object
    id*: cint
    bev*: ptr bufferevent
    # simple fragmentation support
    assembling: bool
    fragOpcode: int
    assembleBuf: seq[byte]
    # user callbacks
    onMessage*: MessageCb
    onClose*: CloseCb
    onError*: ErrorCb
    onOpen*: OpenCb

  WebSocketConnection* = ref WebSocketConnectionImpl


# Convenience: register callbacks
proc setOnMessage*(ws: ptr WebSocketConnectionImpl, cb: MessageCb) = ws.onMessage = cb
proc setOnClose*(ws: ptr WebSocketConnectionImpl, cb: CloseCb) = ws.onClose = cb
proc setOnError*(ws: ptr WebSocketConnectionImpl, cb: ErrorCb) = ws.onError = cb
proc setOnOpen*(ws: ptr WebSocketConnectionImpl, cb: OpenCb) = ws.onOpen = cb

proc writeFrame(bev: ptr bufferevent, opcode: int, payload: openArray[byte])

# Core versions operate on ptr impl:
proc sendFrame*(c: ptr WebSocketConnectionImpl, opcode: int, payload: openArray[byte]) =
  if c.isNil or c.bev.isNil: return
  writeFrame(c.bev, opcode, payload)

proc sendText*(c: ptr WebSocketConnectionImpl, s: string) =
  if s.len == 0: c.sendFrame(0x1, [])
  else:          c.sendFrame(0x1, s.toOpenArrayByte(0, s.len-1))

proc sendBinary*(c: ptr WebSocketConnectionImpl, data: openArray[byte]) =
  c.sendFrame(0x2, data)

proc sendPing*(c: ptr WebSocketConnectionImpl, data: openArray[byte] = []) =
  c.sendFrame(0x9, data)

proc close*(c: ptr WebSocketConnectionImpl, code: int = 1000, reason = "") =
  var payload: seq[byte] = @[]
  if code != 0:
    payload.setLen(2 + reason.len)
    payload[0] = uint8((code shr 8) and 0xFF)
    payload[1] = uint8(code and 0xFF)
    for i, ch in reason: payload[2+i] = uint8(ch.ord and 0xFF)
  c.sendFrame(0x8, payload)

# Thin wrappers so existing code using the ref still works:
proc sendFrame*(ws: WebSocketConnection, opcode: int, payload: openArray[byte]) =
  if ws.isNil: return
  sendFrame(addr ws[], opcode, payload)

proc sendText*(ws: WebSocketConnection, s: string) =
  if ws.isNil: return
  sendText(addr ws[], s)

proc sendBinary*(ws: WebSocketConnection, data: openArray[byte]) =
  if ws.isNil: return
  sendBinary(addr ws[], data)

proc sendPing*(ws: WebSocketConnection, data: openArray[byte] = []) =
  if ws.isNil: return
  sendPing(addr ws[], data)

proc close*(ws: WebSocketConnection, code: int = 1000, reason = "") =
  if ws.isNil: return
  close(addr ws[], code, reason)

# Perform an RFC6455 upgrade on a libevent request and return a connection.
proc websocketUpgrade*(req: ptr evhttp_request,
          onOpen: OpenCb = nil,
          onMessage: MessageCb = nil,
          onClose: CloseCb = nil,
          onError: ErrorCb = nil): WebSocketConnection

# ===== Internals =====

const wsGuid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

proc computeAccept(key: cstring): string =
  let digest = sha1.secureHash($key & wsGuid) # array[20, byte]
  let shaArray = cast[array[0 .. 19, uint8]](digest)
  result = base64.encode(shaArray)

# Global registry: keep refs alive while bev exists
var gConns: Table[ptr bufferevent, WebSocketConnection]

# Framing
proc writeFrame(bev: ptr bufferevent, opcode: int, payload: openArray[byte]) =
  if bev.isNil: return
  let outbuf = bufferevent_get_output(bev)
  var b0: uint8 = uint8(0x80 or (opcode and 0x0F)) # FIN=1
  discard evbuffer_add(outbuf, addr b0, 1)
  let n = payload.len
  if n < 126:
    var b1: uint8 = uint8(n)
    discard evbuffer_add(outbuf, addr b1, 1)
  elif n <= 0xFFFF:
    var b1: uint8 = 126
    discard evbuffer_add(outbuf, addr b1, 1)
    var l16: array[2, uint8]
    l16[0] = uint8((n shr 8) and 0xFF)
    l16[1] = uint8(n and 0xFF)
    discard evbuffer_add(outbuf, addr l16[0], 2)
  else:
    var b1: uint8 = 127
    discard evbuffer_add(outbuf, addr b1, 1)
    var l64: array[8, uint8]
    var v = uint64(n)
    for i in 0 ..< 8:
      l64[7 - i] = uint8(v and 0xFF); v = v shr 8
    discard evbuffer_add(outbuf, addr l64[0], 8)
  if n > 0:
    discard evbuffer_add(outbuf, unsafeAddr payload[0], csize_t(n))

# Parser using pullup + drain
proc parseFrames(ws: ptr WebSocketConnectionImpl, inbuf: ptr Evbuffer) =
  while true:
    let avail = evbuffer_get_length(inbuf).int
    if avail < 2: break
    # Peek first 2 bytes
    var p = evbuffer_pullup(inbuf, 2)
    if p.isNil: break
    let u = cast[ptr UncheckedArray[uint8]](p)
    let b0 = u[0]; let b1 = u[1]
    let fin = int((b0 shr 7) and 1)
    let opcode = int(b0 and 0x0F)
    let masked = int((b1 shr 7) and 1)
    var plen: uint64 = uint64(b1 and 0x7F)
    var header = 2
    # Extended length?
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
    # Mask key?
    var maskKey: array[4, uint8]
    if masked == 1:
      if avail < header + 4: break
      discard evbuffer_pullup(inbuf, header + 4)
      let m = cast[ptr UncheckedArray[uint8]](evbuffer_pullup(inbuf, header + 4))
      for i in 0 ..< 4: maskKey[i] = m[header + i]
      header += 4
    # Ensure full frame present
    let need = header + int(plen)
    if avail < need: break
    # Now pull up the entire frame to a contiguous span
    let frame = cast[ptr UncheckedArray[uint8]](evbuffer_pullup(inbuf, need))
    # Extract payload
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
    # Drain consumed bytes
    discard evbuffer_drain(inbuf, csize_t(need))
    # Handle opcodes / fragmentation
    case opcode
    of 0x0:
      # continuation
      if not ws.assembling:
        if not ws.onError.isNil: ws.onError(addr(ws[]), "Unexpected continuation frame")
        ws.close(1002, "Protocol error")
        return
      ws.assembleBuf.add payload
      if fin == 1:
        let finalOp = ws.fragOpcode
        ws.assembling = false
        if not ws.onMessage.isNil: ws.onMessage(addr(ws[]), finalOp, ws.assembleBuf)
        ws.assembleBuf.setLen(0)
    of 0x1, 0x2:
      if fin == 1:
        if not ws.onMessage.isNil: ws.onMessage(addr(ws[]), opcode, payload)
      else:
        ws.assembling = true
        ws.fragOpcode = opcode
        ws.assembleBuf.setLen(0)
        ws.assembleBuf.add payload
    of 0x8:
      # CLOSE: echo and notify
      ws.sendFrame(0x8, payload)
      if not ws.onClose.isNil:
        var code = 1000; var reason = ""
        if payload.len >= 2:
          code = (int(payload[0]) shl 8) or int(payload[1])
          if payload.len > 2:
            reason = cast[string](payload[2 ..^ 1])
        ws.onClose(addr(ws[]), code, reason)
      # libevent will signal EOF; we'll free there
      return
    of 0x9:
      # PING -> PONG
      ws.sendFrame(0xA, payload)
    of 0xA:
      discard # PONG: ignore
    else:
      # unknown / control frame error
      ws.close(1003, "Unsupported opcode")
      return

# C callbacks
proc bev_readcb(bev: ptr bufferevent, ctx: pointer) {.cdecl.} =
  let ws = cast[ptr WebSocketConnectionImpl](ctx)
  if ws.isNil: return
  let inbuf = bufferevent_get_input(bev)
  ws.parseFrames(inbuf)

proc bev_eventcb(bev: ptr bufferevent, what: cshort, ctx: pointer) {.cdecl.} =
  let ws = cast[ptr WebSocketConnectionImpl](ctx)
  if (what and BEV_EVENT_ERROR.cshort) != 0:
    if not ws.isNil and not ws.onError.isNil:
      ws.onError(addr(ws[]), "bufferevent error")
  if (what and BEV_EVENT_EOF.cshort) != 0 or (what and BEV_EVENT_ERROR.cshort) != 0:
    # free and unroot
    if not ws.isNil and not ws.onClose.isNil:
      ws.onClose(addr(ws[]), 1000, "")
    if not ws.isNil:
      gConns.del(ws.bev)
    if not bev.isNil: bufferevent_free(bev)

# Upgrade helper
proc websocketUpgrade(req: ptr evhttp_request,
                      onOpen: OpenCb = nil,
                      onMessage: MessageCb = nil,
                      onClose: CloseCb = nil,
                      onError: ErrorCb = nil): WebSocketConnection =
  let inHeaders = evhttp_request_get_input_headers(req)
  if inHeaders.isNil:
    evhttp_send_reply(req, HTTP_BADREQUEST, "Bad Request", nil)
    return nil
  let skey = evhttp_find_header(inHeaders, "Sec-WebSocket-Key")
  if skey.isNil:
    evhttp_send_reply(req, HTTP_BADREQUEST, "Missing WebSocket Key", nil)
    return nil
  let outHeaders = evhttp_request_get_output_headers(req)
  discard evhttp_add_header(outHeaders, "Upgrade", "websocket")
  discard evhttp_add_header(outHeaders, "Connection", "Upgrade")
  let accept = computeAccept(skey)
  discard evhttp_add_header(outHeaders, "Sec-WebSocket-Accept", accept.cstring)
  evhttp_request_own(req)
  evhttp_send_reply_start(req, 101, "Switching Protocols")

  let conn = evhttp_request_get_connection(req)
  if conn.isNil:
    evhttp_send_reply_end(req)
    return nil
  let bev = evhttp_connection_get_bufferevent(conn)
  if bev.isNil:
    evhttp_send_reply_end(req)
    return nil

  # Create connection object and root it
  result = WebSocketConnection(
    bev: cast[ptr bufferevent](bev),
    assembling: false,
    fragOpcode: 0,
    assembleBuf: @[],
    onMessage: onMessage,
    onClose: onClose,
    onError: onError,
    onOpen: onOpen
  )
  result.id = bufferevent_getfd(result.bev)
  gConns[result.bev] = result

  bufferevent_setcb(result.bev, bev_readcb, nil, bev_eventcb, cast[pointer](result))
  discard bufferevent_enable(result.bev, BEV_EVENT_READING or BEV_EVENT_WRITING)
  # Call onOpen if provided
  if not result.onOpen.isNil:
    result.onOpen(addr result[])
  evhttp_send_reply_end(req)

# ===== Example usage (optional) =====
# when isMainModule:
#   {.passL:"-L/opt/local/lib -levent", passC:"-I /opt/local/include".}
#   let base = event_base_new()
#   let httpd = evhttp_new(base)

#   proc onMessage(c: ptr WebSocketConnectionImpl, opcode: int, data: openArray[byte]) {.gcsafe.} =
#     {.gcsafe.}:
#       if opcode == 0x1: # text
#         let s = cast[string](data.toSeq)
#         echo s
#         sendText(c, "echo: " & s)
#       else:
#         sendBinary(c, @data)

#   proc onClose(c: ptr WebSocketConnectionImpl, code: int, reason: string) =
#     discard

#   proc onError(c: ptr WebSocketConnectionImpl, err: string) =
#     discard

#   proc onOpen(c: ptr WebSocketConnectionImpl) =
#     echo "WebSocket connection opened: ", cast[int](c)

#   discard evhttp_set_cb(httpd, "/live",
#     proc (req: ptr evhttp_request, arg: pointer) {.cdecl.} =
#       let ws = websocketUpgrade(req,
#         onOpen = onOpen,
#         onMessage = onMessage,
#         onClose = onClose,
#         onError = onError)
#       discard ws
#     , nil)
#   discard evhttp_bind_socket(httpd, "0.0.0.0", 8080)
#   discard event_base_loop(base, 0)
