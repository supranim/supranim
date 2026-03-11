#
# Supranim is a full-featured web framework for building
# web apps & microservices in Nim.
# 
#   (c) 2025 LGPL-2-or-later License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#

import std/[tables, sequtils, posix, atomics]
import pkg/libevent/bindings/[event, buffer, threaded]

export event, SockAddr_storage, Socklen, bindSocket, SocketHandle, close

## This module implements a high-performance UDP server using Libevent.
## It can be used in a single-threaded event loop or in multi-threaded setups
## offering low-latency handling of UDP packets and high-concurrency via worker threads.
## 
## The server supports both simple packet handling and ordered packet processing using
## sequence numbers, making it suitable for applications like real-time gaming,
## telemetry, or any UDP-based protocol.

type
  OnReadCallback* =
      proc(server: UdpServer, data: pointer, len: csize_t,  
            res: SockAddr_storage, addrlen: Socklen) {.nimcall.}
    ## Callback type for handling incoming UDP data.
  
  OrderedReadCallback* = proc(server: UdpServer, data: pointer, len: csize_t,
                              seqNum: uint32, res: SockAddr_storage, addrlen: Socklen) {.nimcall.}
    ## Callback type for handling incoming UDP data with sequence number for ordered processing.

  UdpOrderState = object
    # State for managing ordered packet processing.
    expectedSeq: uint32
      # Next expected sequence number for ordered processing.
    buffer: Table[uint32, (pointer, csize_t, SockAddr_storage, Socklen)]
      # Buffer for out-of-order packets, keyed by sequence number.

  UdpServer* = ref object
    ## The `UdpServer` type represents a UDP server that can handle incoming packets and send responses.
    base: ptr event_base
      # Event base for the UDP server.
    sock: SocketHandle
      # UDP socket file descriptor.
    ev: ptr event
      # Event structure for the UDP server.
    rbuf: ptr Evbuffer
      # Read buffer.
    wbuf: ptr Evbuffer
      # Write buffer.
    port*: int
      # Port number the server is listening on.
    onRead: OnReadCallback
      # Callback for read events.
    onWrite: proc(server: UdpServer) {.nimcall.}
      # Callback for write events.
    onClose: proc(server: UdpServer) {.nimcall.}
      # Callback for close events.
    closed: bool
      # Indicates if the server is closed.
    orderState: UdpOrderState
      # State for ordered packet processing.
    onOrderedRead: OrderedReadCallback
      # Callback for ordered read events.

  StartupCallback* = proc() {.gcsafe.}
    ## Callback type for server startup, useful in multi-threaded
    ## scenarios to signal when the server is ready.

  UdpWorkerCtx = object
    # Context for worker threads running a UDP server.
    port: int
      # Port number for the UDP server.
    onRead: OnReadCallback
      # Callback for read events.
    onOrderedRead: OrderedReadCallback
      # Callback for ordered read events.
    startupCallback: StartupCallback
      # Optional callback to signal when the server has started.
  
  UdpServerError* = object of CatchableError
    ## Custom error type for UDP server-related errors.

proc start*(server: UdpServer) {.gcsafe.}
proc close*(server: UdpServer) {.gcsafe.}

var gUdpLibeventThreadingInit: Atomic[bool]

proc ensureLibeventThreading() =
  if not gUdpLibeventThreadingInit.load(moAcquire):
    doAssert evthread_use_pthreads() == 0, "evthread_use_pthreads failed"
    gUdpLibeventThreadingInit.store(true, moRelease)

proc newUdpSocket(port: int, reusePort: bool): SocketHandle =
  let sock = socket(AF_INET, SOCK_DGRAM, 0)
  if sock.int < 0:
    raise newException(OSError, "Failed to create UDP socket")

  var one: cint = 1
  doAssert setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, addr one, SockLen(sizeof(one))) == 0,
    "setsockopt(SO_REUSEADDR) failed"

  when declared(SO_REUSEPORT):
    if reusePort:
      doAssert setsockopt(sock, SOL_SOCKET, SO_REUSEPORT, addr one, SockLen(sizeof(one))) == 0,
        "setsockopt(SO_REUSEPORT) failed"

  var res: SockAddr_in
  res.sin_family = AF_INET.uint8
  res.sin_port = htons(port.uint16)
  res.sin_addr.s_addr = htonl(INADDR_ANY)

  if bindSocket(sock, cast[ptr SockAddr](res.addr), sizeof(res).Socklen) < 0:
    assert close(sock) == 0
    raise newException(OSError, "Failed to bind UDP socket")

  result = sock

proc encodeSeqPacket*(data: pointer, len: csize_t, seqNum: uint32): (pointer, csize_t) =
  # Helper to encode/decode sequence number (first 4 bytes of packet)
  let totalLen = len + 4
  let buf = alloc(totalLen)
  cast[ptr uint32](buf)[] = seqNum
  # Use pointer arithmetic via cast
  copyMem(cast[pointer](cast[uint](buf) + 4), data, len)
  (buf, totalLen)

proc decodeSeqPacket(data: pointer, len: csize_t): (uint32, pointer, csize_t) =
  # Helper to decode sequence number from packet. Returns (seqNum, payloadPtr, payloadLen).
  if len < 4: return (0'u32, nil, 0)
  let seqNum = cast[ptr uint32](data)[]
  # Use pointer arithmetic via cast
  (seqNum, cast[pointer](cast[uint](data) + 4), len - 4)

proc udpEventCb(fd: cint, events: cshort, arg: pointer) {.cdecl.} =
  # Libevent callback for UDP events. Handles both read and write events,
  # and manages ordered packet processing if enabled.
  let server = cast[UdpServer](arg)
  if (events and EV_READ.cshort) != 0:
    var
      res: SockAddr_storage
      addrlen = sizeof(res).Socklen
      buf = alloc(65536)
    let n = recvfrom(SocketHandle(server.sock), buf, 65536, 0, cast[ptr SockAddr](res.addr), addrlen.addr)
    if n > 0:
      discard evbuffer_add(server.rbuf, buf, n.csize_t)
      if not server.onOrderedRead.isNil:
        let (seqNum, payload, payloadLen) = decodeSeqPacket(buf, n.csize_t)
        let state = addr(server.orderState)
        # Buffer or deliver in order
        if seqNum == state.expectedSeq:
          server.onOrderedRead(server, payload, payloadLen, seqNum, res, addrlen)
          inc(state.expectedSeq)
          # Deliver any buffered packets in order
          while state.buffer.hasKey(state.expectedSeq):
            let (pdata, plen, pres, plenaddr) = state.buffer[state.expectedSeq]
            server.onOrderedRead(server, pdata, plen, state.expectedSeq, pres, plenaddr)
            state.buffer.del(state.expectedSeq)
            inc(state.expectedSeq)
        elif seqNum > state.expectedSeq:
          # Buffer out-of-order
          state.buffer[seqNum] = (payload, payloadLen, res, addrlen)
        # else: duplicate or old, ignore
      elif not server.onRead.isNil:
        server.onRead(server, buf, n.csize_t, res, addrlen)
    dealloc(buf)
  if (events and EV_WRITE.cshort) != 0:
    let wlen = evbuffer_get_length(server.wbuf)
    if wlen > 0:
      var res: SockAddr_storage
      var addrlen = sizeof(res).Socklen
      # For simplicity, send to last received addr or require user to set
      # Here, just a placeholder: user should set destination before write
      # TODO: Add destination management
      discard
    if not server.onWrite.isNil:
      server.onWrite(server)

proc newUdpServer*(port: int, onRead: OnReadCallback = nil,
            onOrderedRead: OrderedReadCallback = nil,
            reusePort: bool = false,
            multithreaded: bool = false): UdpServer =
  ## Create a new UDP server listening on the specified port.
  ## 
  ## The `onRead` callback is invoked for each incoming packet.
  ## The `onOrderedRead` callback is invoked for each incoming packet with sequence number handling.
  ## 
  ## If both callbacks are provided, `onOrderedRead` takes precedence.
  let sock = newUdpSocket(port, reusePort)

  let base: ptr event_base = event_base_new()
  if base == nil:
    discard close(sock)
    raise newException(UdpServerError, "Failed to create event base")

  let server = UdpServer(
    base: base,
    sock: sock,
    rbuf: evbuffer_new(),
    wbuf: evbuffer_new(),
    onRead: onRead,
    onOrderedRead: onOrderedRead,
    closed: false,
    port: port,
    orderState: UdpOrderState(
      expectedSeq: 0,
      buffer: initTable[uint32, (pointer, csize_t, SockAddr_storage, Socklen)]()
    )
  )
  server.ev = event_new(base, sock.cint, (EV_READ or EV_PERSIST).cushort, udpEventCb, cast[pointer](server))
  discard event_add(server.ev, nil)
  return server

proc udpWorker(ctxArg: ptr UdpWorkerCtx) {.thread.} =
  # Worker thread procedure for running a UDP server. Initializes the
  # server based on the provided context, and starts the event loop.
  let ctx = ctxArg[]
  var server = newUdpServer(
    port = ctx.port,
    onRead = ctx.onRead,
    onOrderedRead = ctx.onOrderedRead,
    reusePort = true
  )
  if ctx.startupCallback != nil:
    ctx.startupCallback()
  server.start()
  server.close()
  dealloc(ctxArg)

proc udpSendTo*(server: UdpServer, data: pointer, len: csize_t,
                  res: SockAddr_storage, addrlen: Socklen, retries: int = 1, delayMs: int = 0): int =
  ## Send UDP packet, retrying up to `retries` times if sendto fails.
  var attempt = 0
  while attempt < retries:
    let sent = sendto(server.sock, data, len.int, 0, cast[ptr SockAddr](res.addr), addrlen)
    if sent == len.int:
      return sent
    attempt.inc
    if attempt < retries and delayMs > 0:
      discard sleep(delayMs.cint)
  return -1

proc udpWrite*(server: UdpServer, data: pointer, len: csize_t) =
  ## Queue data to be sent. Actual sending occurs in the event loop.
  discard evbuffer_add(server.wbuf, data, len)
  # Optionally trigger write event
  if not server.ev.isNil:
    discard event_add(server.ev, nil)

proc udpRead*(server: UdpServer, data: pointer, maxlen: csize_t): int =
  ## Read data from the server's read buffer into `data` up to `maxlen` bytes.
  evbuffer_remove(server.rbuf, data, maxlen)

proc close*(server: UdpServer) {.gcsafe.} =
  ## Close the UDP server and free resources.
  {.gcsafe.}:
    if server.closed: return
    server.closed = true

    if not server.ev.isNil:
      event_free(server.ev)
      server.ev = nil
    if not server.rbuf.isNil:
      evbuffer_free(server.rbuf)
      server.rbuf = nil
    if not server.wbuf.isNil:
      evbuffer_free(server.wbuf)
      server.wbuf = nil
    if server.sock.int >= 0:
      assert close(server.sock) == 0
    if not server.base.isNil:
      event_base_free(server.base)
      server.base = nil

    if not server.onClose.isNil:
      server.onClose(server)

proc start*(server: UdpServer) =
  ## Start the UDP server's event loop. This call blocks until the server is closed.
  if server.closed: raise newException(UdpServerError, "Cannot start a closed server")
  discard event_base_dispatch(server.base)

proc start*(server: var UdpServer, threads: uint, startupCallback: StartupCallback = nil) =
  ## Start the UDP server in a multi-threaded setup with the specified number of worker threads.
  ## Each thread runs its own event loop and can handle incoming packets concurrently.
  when not compileOption("threads"):
    {.error: "Multi-threaded UDP server requires --threads:on".}
  assert threads > 1, "Use start() for single-threaded mode"
  ensureLibeventThreading()

  let port = server.port
  let onRead = server.onRead
  let onOrderedRead = server.onOrderedRead

  # Dispose bootstrap instance before worker pool starts
  server.close()

  var workers = newSeq[Thread[ptr UdpWorkerCtx]](threads - 1)
  for i in 0 ..< workers.len:
    let ctx = cast[ptr UdpWorkerCtx](alloc0(sizeof(UdpWorkerCtx)))
    ctx.port = port
    ctx.onRead = onRead
    ctx.onOrderedRead = onOrderedRead
    ctx.startupCallback = startupCallback
    createThread(workers[i], udpWorker, ctx)

  let mainCtx = cast[ptr UdpWorkerCtx](alloc0(sizeof(UdpWorkerCtx)))
  mainCtx.port = port
  mainCtx.onRead = onRead
  mainCtx.onOrderedRead = onOrderedRead
  mainCtx.startupCallback = startupCallback
  udpWorker(mainCtx)

  for t in workers:
    joinThread(t)
