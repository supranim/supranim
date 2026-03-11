#
# Supranim is a full-featured web framework for building
# web apps & microservices in Nim.
# 
#   (c) 2025 LGPL-2-or-later License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#

import std/posix
import pkg/libevent/bindings/[event, buffer]

## This module implements a UDP client using Libevent for asynchronous I/O.
## It provides a high-level interface for sending and receiving UDP packets,
## with support for callbacks and event-driven programming.

type
  UdpClient* = object
    ## UDP client object.
    base*: ptr event_base
      ## Event base for the UDP client.
    sock*: SocketHandle
      ## UDP socket file descriptor.
    ev*: ptr event
      ## Event structure for the UDP client.
    rbuf*: ptr Evbuffer
      ## Read buffer.
    wbuf*: ptr Evbuffer
      ## Write buffer.
    closed*: bool
      ## Indicates if the client is closed.
    remoteAddr*: SockAddr_storage
      ## Remote server address.
    remoteLen*: Socklen
      ## Length of remote address.

  UdpClientReadCallback* = proc(client: var UdpClient, data: pointer,
                              len: csize_t, res: SockAddr_storage, addrlen: Socklen) {.nimcall.}
    ## Type for UDP client read callback. Called when a UDP packet is received.

  UdpClientError* = object of CatchableError
    ## Custom error type for UDP client-related errors.

proc newUdpClient*(remotePort: int, remoteIp = "0.0.0.0"): UdpClient =
  ## Create a new UDP client and connect to remoteIp:remotePort
  let sock = socket(AF_INET, SOCK_DGRAM, 0)
  if sock.int < 0: raise newException(OSError, "Failed to create UDP socket")
  var res: SockAddr_in
  res.sin_family = AF_INET.uint8
  res.sin_port = htons(remotePort.uint16)
  res.sin_addr.s_addr = inet_addr(remoteIp)
  let remoteAddr = cast[SockAddr_storage](res)
  let remoteLen = sizeof(res).Socklen
  var base: ptr event_base = event_base_new()
  if base == nil:
    raise newException(UdpClientError, "Failed to create event base")
  let client = UdpClient(
    base: base,
    sock: sock,
    rbuf: evbuffer_new(),
    wbuf: evbuffer_new(),
    closed: false,
    remoteAddr: remoteAddr,
    remoteLen: remoteLen
  )
  return client

proc send*(client: var UdpClient, data: pointer, len: csize_t): int =
  ## Send UDP packet to the connected remote address.
  sendto(client.sock, data, len.int, 0, cast[ptr SockAddr](client.remoteAddr.addr), client.remoteLen)

proc send*(client: var UdpClient, data: string): int {.discardable.} =
  ## Send a string as a UDP packet.
  send(client, cast[pointer](cstring(data)), csize_t(data.len))

proc udpRecv*(client: var UdpClient, data: pointer, maxlen: csize_t, res: var SockAddr_storage, addrlen: var Socklen): int =
  ## Receive UDP packet, returns number of bytes received.
  recvfrom(client.sock, data, maxlen.int, 0, cast[ptr SockAddr](res.addr), addrlen.addr)

proc close*(client: var UdpClient) =
  ## Close the UDP client and free resources.
  if client.closed: return
  client.closed = true
  if not client.rbuf.isNil: evbuffer_free(client.rbuf)
  if not client.wbuf.isNil: evbuffer_free(client.wbuf)
  if client.sock.int >= 0:
    discard close(client.sock)
