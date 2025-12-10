#
# Supranim is a full-featured web framework for building
# web apps & microservices in Nim.
# 
#   (c) 2025 MIT License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#

import std/[strutils, base64, sha1, tables]
import libevent/bindings/[http, buffer, bufferevent, event]

type
  WebSocketFrameKind* = enum
    wsNone = 0
    wsText = 1
    wsBinary = 2
    wsClose = 8
    wsPing = 9
    wsPong = 10

  WebSocketClient* = ref object
    bev*: ptr bufferevent
    fd*: cint
    closed*: bool

  WebSocketServer* = ref object
    connections*: seq[WebSocketClient]
    onOpen: WebSocketOnOpen
    onMessage: WebSocketOnMessage
    onClose: WebSocketOnClose

  WebSocketPools* = object
    servers: Table[string, WebSocketServer]

  WebSocketOnOpen* = proc(ws: WebSocketClient) {.closure.}
  WebSocketOnMessage* = proc(ws: WebSocketClient, msg: string) {.closure.}
  WebSocketOnClose* = proc(ws: WebSocketClient) {.closure.}

const magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

proc initWebSocketPools*: WebSocketPools =
  result.servers = initTable[string, WebSocketServer]()

proc computeAcceptKey(secWebSocketKey: string): string =
  let sha = sha1.secureHash(secWebSocketKey & magic)
  let shaArray = cast[array[0 .. 19, uint8]](sha)
  result = base64.encode(shaArray)

proc isWebSocketUpgrade*(req: ptr evhttp_request): bool =
  let headers = evhttp_request_get_input_headers(req)
  let upgrade = $evhttp_find_header(headers, "Upgrade")
  let connection = $evhttp_find_header(headers, "Connection")
  result = upgrade.toLowerAscii == "websocket" and connection.toLowerAscii.contains("upgrade")

proc getHeader(req: ptr evhttp_request, key: string): string =
  let headers = evhttp_request_get_input_headers(req)
  result = $evhttp_find_header(headers, key)

proc hasHeader(req: ptr evhttp_request, key: string): bool =
  let headers = evhttp_request_get_input_headers(req)
  result = evhttp_find_header(headers, key) != nil

proc sendHandshakeResponse(req: ptr evhttp_request, acceptKey: string) =
  let headers = evhttp_request_get_output_headers(req)
  discard evhttp_add_header(headers, "Upgrade", "websocket")
  discard evhttp_add_header(headers, "Connection", "Upgrade")
  discard evhttp_add_header(headers, "Sec-WebSocket-Accept", acceptKey)
  evhttp_send_reply_start(req, 101, "Switching Protocols")
  evhttp_send_reply_end(req)

proc parseFrameBev(bev: ptr bufferevent): tuple[fin: bool, kind: WebSocketFrameKind, payload: string, frameSize: int] =
  if bev == nil: return (false, wsNone, "", 0)
  let input = bufferevent_get_input(bev)
  if input == nil: return (false, wsNone, "", 0)
  let avail = evbuffer_get_length(input)
  if avail < 2: return (false, wsNone, "", 0)
  var hdr: array[2, byte]
  let copyoutRes = evbuffer_copyout(input, addr hdr[0], 2)
  if copyoutRes != 2: return (false, wsNone, "", 0)
  let fin = (hdr[0] and 0x80) != 0
  let opcode = WebSocketFrameKind(hdr[0] and 0x0F)
  let masked = (hdr[1] and 0x80) != 0
  var payloadLen = hdr[1] and 0x7F
  var headerSize = 2
  if payloadLen == 126:
    if avail < 4: return (false, wsNone, "", 0)
    var extHdr: array[4, byte]
    let extRes = evbuffer_copyout(input, addr extHdr[0], 4)
    if extRes != 4: return (false, wsNone, "", 0)
    payloadLen = (uint8(extHdr[2]) shl 8) or uint8(extHdr[3])
    headerSize = 4
  elif payloadLen == 127:
    # For simplicity, skip 64-bit payload support
    return (false, wsNone, "", 0)
  var mask: array[4, byte]
  if masked:
    if int(avail) < headerSize + 4: return (false, wsNone, "", 0)
    var maskBuf: array[8, byte] # enough to cover header + mask
    let maskRes = evbuffer_copyout(input, addr maskBuf[0], csize_t(headerSize + 4))
    if maskRes != headerSize + 4: return (false, wsNone, "", 0)
    for i in 0 ..< 4:
      mask[i] = maskBuf[headerSize + i]
    headerSize += 4
  if int(avail) < headerSize + int(payloadLen): return (false, wsNone, "", 0)
  var payload: string = newString(payloadLen)
  if payloadLen > 0:
    var payBuf: array[4096, byte] # adjust size if needed
    let payRes = evbuffer_copyout(input, addr payBuf[0], csize_t(headerSize + int(payloadLen)))
    if payRes != headerSize + int(payloadLen):
      return (false, wsNone, "", 0)
    if masked:
      for i in 0 ..< int(payloadLen):
        payload[i] = chr(ord(payBuf[headerSize + i]) xor int(mask[i mod 4]))
    else:
      for i in 0 ..< int(payloadLen):
        payload[i] = chr(ord(payBuf[headerSize + i]))
  let frameSize = headerSize + int(payloadLen)
  (fin, opcode, payload, frameSize)

proc sendFrameBev(bev: ptr bufferevent, kind: WebSocketFrameKind, payload: string = "") =
  var hdr: array[2, byte]
  hdr[0] = (0x80'u8 or kind.uint8)
  let len = payload.len
  let output = bufferevent_get_output(bev)
  if len < 126:
    hdr[1] = len.uint8
    discard evbuffer_add(output, addr hdr[0], 2)
  elif len < 65536:
    hdr[1] = 126
    discard evbuffer_add(output, addr hdr[0], 2)
    var ext: array[2, byte]
    ext[0] = (len shr 8).uint8
    ext[1] = (len and 0xFF).uint8
    discard evbuffer_add(output, addr ext[0], 2)
  else:
    # For simplicity, skip 64-bit payload support
    return
  if len > 0:
    discard evbuffer_add(output, unsafeAddr payload[0], len.csize_t)

proc send*(ws: WebSocketClient, msg: string) =
  if not ws.closed and ws.bev != nil:
    sendFrameBev(ws.bev, wsText, msg)

proc onEvent(wss: WebSocketServer) =
  var toRemove: seq[int] = @[]
  let conns = wss.connections
  for i in 0 ..< conns.len:
    let client = conns[i]
    if client == nil or client.closed or client.bev == nil:
      toRemove.add(i)
      continue
    let input = bufferevent_get_input(client.bev)
    if input == nil:
      client.closed = true
      if client.bev != nil:
        bufferevent_free(client.bev)
        client.bev = nil # Mark as unusable
      toRemove.add(i)
      continue
    while true:
      let avail = evbuffer_get_length(input)
      if avail < 2: break
      let (fin, kind, payload, frameSize) = parseFrameBev(client.bev)
      if frameSize == 0: break
      discard evbuffer_drain(input, frameSize.csize_t)
      case kind
      of wsText:
        if payload.len > 0 and wss.onMessage != nil:
          wss.onMessage(client, payload)
      of wsClose:
        client.closed = true
        if client.bev != nil:
          bufferevent_free(client.bev)
          client.bev = nil # Mark as unusable after close
        if wss.onClose != nil: wss.onClose(client)
        toRemove.add(i)
        break
      of wsPing:
        sendFrameBev(client.bev, wsPong, payload)
      of wsPong, wsNone: discard
      else: discard
  # Remove closed clients immediately
  for i in countdown(toRemove.high, 0):
    if i >= 0 and i < wss.connections.len:
      wss.connections.delete(i)

proc pollWebSocketServers*(pools: var WebSocketPools) =
  for route, server in pools.servers:
    if server == nil: continue
    onEvent(server)

proc getOrCreateWebSocketServer*(pools: var WebSocketPools, route: string,
                                  onOpen: WebSocketOnOpen = nil,
                                  onMessage: WebSocketOnMessage = nil,
                                  onClose: WebSocketOnClose = nil): WebSocketServer =
  ## Retrieves or creates a WebSocketServer for the given route.
  if not pools.servers.hasKey(route):
    var server = WebSocketServer(connections: @[], onOpen: onOpen, onMessage: onMessage, onClose: onClose)
    pools.servers[route] = server
  result = pools.servers[route]

proc acceptWebSocketHandle*(pools: var WebSocketPools, route: string, req: ptr evhttp_request,
                            onOpen: WebSocketOnOpen = nil, onMessage: WebSocketOnMessage = nil,
                            onClose: WebSocketOnClose = nil) =
  ## Accepts a WebSocket connection on the given request.
  let server = getOrCreateWebSocketServer(pools, route, onOpen, onMessage, onClose)
  let ws = WebSocketClient(closed: false)
  if req.hasHeader("Sec-WebSocket-Key"):
    let key = req.getHeader("Sec-WebSocket-Key")
    let acceptKey = computeAcceptKey(key)
    sendHandshakeResponse(req, acceptKey)
    let conn = evhttp_request_get_connection(req)
    ws.bev = cast[ptr bufferevent](evhttp_connection_get_bufferevent(conn))
    if ws.bev == nil:
      echo "WebSocket error: hijackBev failed"
      return
    ws.fd = bufferevent_getfd(ws.bev)
    server.connections.add(ws)
    if server.onOpen != nil:
      server.onOpen(ws)
  else:
    evhttp_send_error(req, 400, "Missing Sec-WebSocket-Key")