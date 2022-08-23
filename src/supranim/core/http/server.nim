# Supranim is a simple MVC-style web framework for building
# fast web applications, REST API microservices and other cool things.
# 
# The http module is a modified version of httpbeast.
#          (c) Dominik Picheta
#          https://github.com/dom96/httpbeast
#
# (c) 2022 Supranim is released under MIT License
#          Made by Humans from OpenPeep
#          https://supranim.com | https://github.com/supranim

import std/[selectors, net, nativesockets, os, httpcore, asyncdispatch,
            strutils, parseutils, options, logging, times, tables]

import ../../support/session
import ../../support/uuid

from std/strutils import indent, join
from std/sugar import capture
from std/json import JsonNode, `$`
from std/deques import len

when defined(windows):
    import std/sets
    import std/monotimes
    import std/heapqueue
else:
    import std/posix

export httpcore except parseHeader
export asyncdispatch, options

include ./private/metaserver

proc updateDate(fd: AsyncFD): bool =
    result = false # Returning true signifies we want timer to stop.
    serverDate = now().utc().format("ddd, dd MMM yyyy HH:mm:ss 'GMT'")

proc parseHttpMethod*(data: string, start: int): Option[HttpMethod] =
    ## Parses Request data in order to find the current HttpMethod
    ## According to RFC7230 3.1.1. all HTTP methods are case sensitive
    ## The HttpMethod parser is wrapped into a try/except statement
    ## so in case the http method is invalid will just raise none(HttpMethod) option,
    ## preventing IndexDefect exceptions and other unpleasant errors
    try:
        case data[start]
        of 'G':
            if data[start+1] == 'E' and data[start+2] == 'T':
                return some(HttpGet)
        of 'H':
            if data[start+1] == 'E' and data[start+2] == 'A' and data[start+3] == 'D':
                return some(HttpHead)
        of 'P':
            if data[start+1] == 'O' and data[start+2] == 'S' and data[start+3] == 'T':
                return some(HttpPost)
            if data[start+1] == 'U' and data[start+2] == 'T':
                return some(HttpPut)
            if data[start+1] == 'A' and data[start+2] == 'T' and
                 data[start+3] == 'C' and data[start+4] == 'H':
                return some(HttpPatch)
        of 'D':
            if data[start+1] == 'E' and data[start+2] == 'L' and
                 data[start+3] == 'E' and data[start+4] == 'T' and
                 data[start+5] == 'E':
                return some(HttpDelete)
        of 'O':
            if data[start+1] == 'P' and data[start+2] == 'T' and
                 data[start+3] == 'I' and data[start+4] == 'O' and
                 data[start+5] == 'N' and data[start+6] == 'S':
                return some(HttpOptions)
        else: discard
    except:
        return none(HttpMethod)
    return none(HttpMethod)

# 
# Request Parser
# 

proc parsePath*(data: string, start: int): Option[string] =
    ## Parses the request path from the specified data.
    if unlikely(data.len == 0): return

    # Find the first ' '.
    # We can actually start ahead a little here. Since we know
    # the shortest HTTP method: 'GET'/'PUT'.
    var i = start+2
    while data[i] notin {' ', '\0'}: i.inc()

    if likely(data[i] == ' '):
        # Find the second ' '.
        i.inc() # Skip first ' '.
        let start = i
        while data[i] notin {' ', '\0'}: i.inc()

        if likely(data[i] == ' '):
            return some(data[start..<i])
    else:
        return none(string)

proc parseHeaders*(data: string, start: int): Option[HttpHeaders] =
    if unlikely(data.len == 0): return
    var pairs: seq[(string, string)] = @[]
    var i = start
    # Skip first line containing the method, path and HTTP version.
    while data[i] != '\l': i.inc
    i.inc # Skip \l
    var value = false
    var current: (string, string) = ("", "")
    while i < data.len:
        case data[i]
        of ':':
            if value: current[1].add(':')
            value = true
        of ' ':
            if value:
                if current[1].len != 0:
                    current[1].add(data[i])
            else:
                current[0].add(data[i])
        of '\c':
            discard
        of '\l':
            if current[0].len == 0:
                # End of headers.
                return some(newHttpHeaders(pairs))
            pairs.add(current)
            value = false
            current = ("", "")
        else:
            if value:
                current[1].add(data[i])
            else:
                current[0].add(data[i])
        i.inc()
    return none(HttpHeaders)

proc parseContentLength*(data: string, start: int): int =
    let headers = data.parseHeaders(start)
    if headers.isNone(): return
    if unlikely(not headers.get().hasKey("Content-Length")): return
    discard headers.get()["Content-Length"].parseSaturatedNatural(result)

iterator parseRequests*(data: string): int =
    ## Yields the start position of each request in `data`.
    ##
    ## This is only necessary for support of HTTP pipelining. The assumption
    ## is that there is a request at position `0`, and that there MAY be another
    ## request further in the data buffer.
    var i = 0
    yield i

    while i+3 < len(data):
        if data[i+0] == '\c' and data[i+1] == '\l' and
             data[i+2] == '\c' and data[i+3] == '\l':
            if likely(i+4 == len(data)): break
            i.inc(4)
            if parseHttpMethod(data, i).isNone(): continue
            yield i
        i.inc()

template withRequestData(req: Request, body: untyped) =
    let requestData {.inject.} = addr req.selector.getData(req.client)
    body

#
# Socket API
#

proc initData(fdKind: FdKind, ip = ""): Data =
    Data(fdKind: fdKind,
         sendQueue: "",
         bytesSent: 0,
         data: "",
         headersFinished: false,
         headersFinishPos: -1,          ## By default we assume the fast case: end of data.
         ip: ip
    )

template handleAcceptClient() =
    let (client, address) = fd.SocketHandle.accept()
    if client == osInvalidSocket:
        let lastError = osLastError()
        when defined posix:
            if lastError.int32 == EMFILE:
                warn("Ignoring EMFILE error: ", osErrorMsg(lastError))
                return
        raiseOSError(lastError)
    setBlocking(client, false)
    selector.registerHandle(client, {Event.Read}, initData(Client, ip=address))

template handleClientClosure(selector: Selector[Data], fd: SocketHandle|int, inLoop=true) =
    # TODO: Logging that the socket was closed.
    # TODO: Can POST body be sent with Connection: Close?
    var data: ptr Data = addr selector.getData(fd)
    let isRequestComplete = data.reqFut.isNil or data.reqFut.finished
    if isRequestComplete:
        # The `onRequest` callback isn't in progress, so we can close the socket.
        selector.unregister(fd)
        fd.SocketHandle.close()
    else:
        # Close the socket only once the `onRequest` callback completes.
        data.reqFut.addCallback(
            proc (fut: Future[void]) =
                fd.SocketHandle.close()
        )
        # Unregister fd so that we don't receive any more events for it.
        # Once we do so the `data` will no longer be accessible.
        selector.unregister(fd)
    when inLoop:    break
    else:           return

proc onRequestFutureComplete(theFut: Future[void], selector: Selector[Data], fd: int) =
    if theFut.failed:
        raise theFut.error

template fastHeadersCheck(data: ptr Data): untyped =
    (let res = data.data[^1] == '\l' and data.data[^2] == '\c' and
                         data.data[^3] == '\l' and data.data[^4] == '\c';
     if res: data.headersFinishPos = data.data.len;
     res)

template methodNeedsBody(data: ptr Data): untyped =
    # Only idempotent methods can be pipelined (GET/HEAD/PUT/DELETE), they
    # never need a body, so we just assume `start` at 0.
    (
        let m = parseHttpMethod(data.data, start=0);
        m.isSome() and m.get() in {HttpPost, HttpPut, HttpConnect, HttpPatch}
    )

proc slowHeadersCheck(data: ptr Data): bool =
    # TODO: See how this `unlikely` affects ASM.
    if unlikely(methodNeedsBody(data)):
        # Look for \c\l\c\l inside data.
        data.headersFinishPos = 0
        template ch(i): untyped =
            (
                let pos = data.headersFinishPos+i;
                if pos >= data.data.len: '\0' else: data.data[pos]
            )
        while data.headersFinishPos < data.data.len:
            case ch(0)
            of '\c':
                if ch(1) == '\l' and ch(2) == '\c' and ch(3) == '\l':
                    data.headersFinishPos.inc(4)
                    return true
            else: discard
            data.headersFinishPos.inc()

        data.headersFinishPos = -1

proc bodyInTransit(data: ptr Data): bool =
    assert methodNeedsBody(data), "Calling bodyInTransit now is inefficient."
    assert data.headersFinished
    if data.headersFinishPos == -1: return false
    var trueLen = parseContentLength(data.data, start=0)
    let bodyLen = data.data.len - data.headersFinishPos
    assert(not (bodyLen > trueLen))
    return bodyLen != trueLen

#
# Request & Response API
#
include ./private/request
include ./private/response

template handleClientReadEvent() =
    # Read until EAGAIN. We take advantage of the fact that the client
    # will wait for a response after they send a request. So we can
    # comfortably continue reading until the message ends with \c\l
    # \c\l.
    const size = 256
    var buf: array[size, char]
    while true:
        let ret = recv(fd.SocketHandle, addr buf[0], size, 0.cint)
        if ret == 0: handleClientClosure(selector, fd)
        if ret == -1:
            let lastError = osLastError()
            when defined posix:
                if lastError.int32 in {EWOULDBLOCK, EAGAIN}: break
            else:
                if lastError.int == WSAEWOULDBLOCK: break
            if isDisconnectionError({SocketFlag.SafeDisconn}, lastError):
                handleClientClosure(selector, fd)
            raiseOSError(lastError)

        # Write buffer to our data.
        let origLen = data.data.len
        data.data.setLen(origLen + ret)
        for i in 0 ..< ret:
            data.data[origLen+i] = buf[i]

        if fastHeadersCheck(data) or slowHeadersCheck(data):
            # First line and headers for request received.
            data.headersFinished = true
            when not defined(release):
                if data.sendQueue.len != 0:
                    logging.warn("sendQueue isn't empty.")
                if data.bytesSent != 0:
                    logging.warn("bytesSent isn't empty.")

            # let m = parseHttpMethod(data.data, start=0);
            let waitingForBody = methodNeedsBody(data) and bodyInTransit(data)
            # let waitingForBody = false
            if likely(not waitingForBody):
                for start in parseRequests(data.data):
                    # For pipelined requests, we need to reset this flag.
                    data.headersFinished = true
                    data.requestID = genRequestID()
                    var req = Request(
                        start: start,
                        selector: selector,
                        client: fd.SocketHandle,
                        requestID: data.requestID,
                        ip: data.ip
                    )
                    req.reqHeaders = parseHeaders(req.selector.getData(req.client).data, req.start)
                    template validateResponse(capturedData: ptr Data): untyped =
                        if capturedData.requestID == req.requestID:
                            capturedData.headersFinished = false

                    if validateRequest(req):
                        var res = Response(req: req, headers: newHttpHeaders())
                        data.reqFut = onRequest(req, res)
                        if not data.reqFut.isNil:
                            capture data:
                                data.reqFut.addCallback(
                                    proc (fut: Future[void]) =
                                        onRequestFutureComplete(fut, selector, fd)
                                        validateResponse(data)
                                )
                        else: validateResponse(data)
        if ret != size: break

template handleClientWriteEvent() =
    assert data.sendQueue.len > 0
    assert data.bytesSent < data.sendQueue.len
    # Write the sendQueue.
    when defined posix:
        let leftover = data.sendQueue.len - data.bytesSent
    else:
        let leftover = cint(data.sendQueue.len - data.bytesSent)
    let ret = send(fd.SocketHandle, addr data.sendQueue[data.bytesSent], leftover, 0)
    if ret == -1:
        # Error!
        let lastError = osLastError()
        when defined posix:
            if lastError.int32 in {EWOULDBLOCK, EAGAIN}: break
        else:
            if lastError.int32 == WSAEWOULDBLOCK: break
        if isDisconnectionError({SocketFlag.SafeDisconn}, lastError):
            handleClientClosure(selector, fd)
        raiseOSError(lastError)
    data.bytesSent.inc(ret)
    if data.sendQueue.len == data.bytesSent:
        data.bytesSent = 0
        data.sendQueue.setLen(0)
        data.data.setLen(0)
        selector.updateHandle(fd.SocketHandle, {Event.Read})

proc processEvents(selector: Selector[Data], events: array[64, ReadyKey], count: int, onRequest: OnRequest) =
    for i in 0 ..< count:
        let fd = events[i].fd
        var data: ptr Data = addr(selector.getData(fd))
        # Handle error events first.
        if Event.Error in events[i].events:
            if isDisconnectionError({SocketFlag.SafeDisconn}, events[i].errorCode):
                handleClientClosure(selector, fd)
            raiseOSError(events[i].errorCode)

        case data.fdKind
        of Server:
            if Event.Read in events[i].events:
                handleAcceptClient()
            # else: assert false, "Only Read events are expected for the server"
        of Dispatcher:
            # Handle the dispatcher loop
            when defined posix:
                assert events[i].events == {Event.Read}
                asyncdispatch.poll(0)
            else: discard
        of Client:
            if Event.Read in events[i].events:
                handleClientReadEvent()
            elif Event.Write in events[i].events:
                handleClientWriteEvent()
            # else: assert false

proc eventLoop(app: AppConfig) =
    let selector = newSelector[Data]()
    let server = newSocket(app.domain)
    server.setSockOpt(OptReuseAddr, true)
    server.setSockOpt(OptReusePort, app.isReusable)
    server.bindAddr(app.port, app.address)
    server.listen()
    server.getFd().setBlocking(false)
    selector.registerHandle(server.getFd(), {Event.Read}, initData(Server))

    # Set up timer to get current date/time.
    discard updateDate(0.AsyncFD)
    asyncdispatch.addTimer(1000, false, updateDate)
    let disp = getGlobalDispatcher()
    when defined posix:
        selector.registerHandle(getIoHandler(disp).getFd(), {Event.Read}, initData(Dispatcher))
        var events: array[64, ReadyKey]
        while true:
            let ret = selector.selectInto(-1, events)
            processEvents(selector, events, ret, app.onRequest)
            # Ensure callbacks list doesn't grow forever in asyncdispatch.
            # @SEE https://github.com/nim-lang/Nim/issues/7532.
            # Not processing callbacks can also lead to exceptions being silently lost!
            if unlikely(asyncdispatch.getGlobalDispatcher().callbacks.len > 0):
                asyncdispatch.poll(0)
    else:
        var events: array[64, ReadyKey]
        while true:
            let ret =
                if disp.timers.len > 0:
                    selector.selectInto((disp.timers[0].finishAt - getMonoTime()).inMilliseconds.int, events)
                else:
                    selector.selectInto(20, events)
            if ret > 0:
                processEvents(selector, events, ret, app.onRequest)
            asyncdispatch.poll(0)

proc run*(onRequest: OnRequest) =
    ## Starts the HTTP server and calls `onRequest` for each request.
    ## The ``onRequest`` procedure returns a ``Future[void]`` type. But
    ## unlike most asynchronous procedures in Nim, it can return ``nil``
    ## for better performance, when no async operations are needed.
    # App.printBootStatus()
    # when compileOption("threads"):
        # if App.isMultithreading:
        #     # tuple[onRequest: OnRequest, address: string, port: Port, recyclable: bool]
        #     var threads = newSeq[Thread[AppConfig]](App.getThreads())
        #     for i in 0 ..< App.getThreads():
        #         createThread[AppConfig](
        #             threads[i], eventLoop, (
        #                 onRequest,
        #                 App.getDomain(),
        #                 App.getAddress(),
        #                 App.getPort(),
        #                 App.isRecyclable()
        #             )
        #         )
        #     joinThreads(threads)
        # else: eventLoop((onRequest, App.getDomain(), App.getAddress(), App.getPort(), App.isRecyclable()))
    # else:
    eventLoop((onRequest, Domain.AF_INET, "127.0.0.1", Port(9933), true))