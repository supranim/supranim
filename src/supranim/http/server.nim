# Supranim is a simple Hyper Server and Web Framework developed
# for building safe & fast in-house projects.
# 
# Supranim Server module based on (c) Dom's work for Httpbeast,
# with some improvements and better code readability
# 
# (c) 2021 Supranim is released under MIT License
#          by George Lemon <georgelemon@protonmail.com>
#          
#          Website: https://supranim.com
#          Github Repository: https://github.com/supranim

import std/[selectors, net, nativesockets, os, httpcore, asyncdispatch,
            strutils, posix, parseutils, options, logging, times]

from std/strformat import fmt

import jsony
import ../application

from deques import len
from osproc import countProcessors

# Include the Request Parser
include ./requestParser

export httpcore except parseHeader
export asyncdispatch, options

type
    FdKind = enum
        Server, Client, Dispatcher

    Data = object
        fdKind: FdKind
            ## Determines the fd kind (server, client, dispatcher)
            ## - Client specific data.
            ## A queue of data that needs to be sent when the FD becomes writeable.
        sendQueue: string
            ## The number of characters in `sendQueue` that have been sent already.
        bytesSent: int
            ## Big chunk of data read from client during request.
        data: string
            ## Determines whether `data` contains "\c\l\c\l".
        headersFinished: bool
            ## Determines position of the end of "\c\l\c\l".
        headersFinishPos: int
            ## The address that a `client` connects from.
        ip: string
            ## Future for onRequest handler (may be nil).
        reqFut: Future[void]
            ## Identifier for current request. Mainly for better detection of cross-talk.
        requestID: uint

type
    Request* = object
        selector: Selector[Data]
        client*: SocketHandle
            # Determines where in the data buffer this request starts.
            # Only used for HTTP pipelining.
        start: int
            # Identifier used to distinguish requests.
        requestID*: uint
            # Identifier for current request
        params: seq[RoutePatternTuple]

    Response* = object
        req: Request

    OnRequest* = proc (req: var Request, res: Response): Future[void] {.gcsafe.}
        ## Procedure used on request

    HttpBeastDefect* = ref object of Defect
        ## Catchable object error

    RoutePattern* = enum
        ## Base route patterns
        None, Id, Slug, Alpha, Digits, Date, DateYear, DateMonth, DateDay

    # CacheableRoutes = object
    #     ## Cache routes response for a certain amount of time
    #     expiration: Option[DateTime]

    RoutePatternTuple* = tuple[pattern: RoutePattern, str: string, optional, dynamic: bool]
        ## RoutePattern tuple is used for all Route object instances.
        ## Holds the pattern representation of each path, where
        ## ``pattern`` is one from Pattern enum,

    RoutePatternRequest* = tuple[pattern: RoutePattern, str: string]
        ## Similar to ``RoutePatternTuple``, the only difference is that is used
        ## during runtime for parsing each path request.

const serverInfo = "Supranim"

## Include Response Handler
include ./response

proc initData(fdKind: FdKind, ip = ""): Data =
    Data(fdKind: fdKind,
         sendQueue: "",
         bytesSent: 0,
         data: "",
         headersFinished: false,
         headersFinishPos: -1,          ## By default we assume the fast case: end of data.
         ip: ip
    )

template handleAccept() =
    let (client, address) = fd.SocketHandle.accept()
    if client == osInvalidSocket:
        let lastError = osLastError()
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
    (
        # Only idempotent methods can be pipelined (GET/HEAD/PUT/DELETE), they
        # never need a body, so we just assume `start` at 0.
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

var requestCounter: uint = 0
proc genRequestID(): uint =
    if requestCounter == high(uint):
        requestCounter = 0
    requestCounter += 1
    return requestCounter

proc validateRequest(req: Request): bool {.gcsafe.}
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
                handleAccept()
            else:
                assert false, "Only Read events are expected for the server"
        of Dispatcher:
            # Run the dispatcher loop.
            assert events[i].events == {Event.Read}
            asyncdispatch.poll(0)
        of Client:
            if Event.Read in events[i].events:
                const size = 256
                var buf: array[size, char]
                # Read until EAGAIN. We take advantage of the fact that the client
                # will wait for a response after they send a request. So we can
                # comfortably continue reading until the message ends with \c\l
                # \c\l.
                while true:
                    let ret = recv(fd.SocketHandle, addr buf[0], size, 0.cint)
                    if ret == 0:
                        handleClientClosure(selector, fd)

                    if ret == -1:
                        # Error!
                        let lastError = osLastError()
                        if lastError.int32 in {EWOULDBLOCK, EAGAIN}:
                            break
                        if isDisconnectionError({SocketFlag.SafeDisconn}, lastError):
                            handleClientClosure(selector, fd)
                        raiseOSError(lastError)

                    # Write buffer to our data.
                    let origLen = data.data.len
                    data.data.setLen(origLen + ret)
                    for i in 0 ..< ret: data.data[origLen+i] = buf[i]

                    if fastHeadersCheck(data) or slowHeadersCheck(data):
                        # First line and headers for request received.
                        data.headersFinished = true
                        when not defined(release):
                            if data.sendQueue.len != 0:
                                logging.warn("sendQueue isn't empty.")
                            if data.bytesSent != 0:
                                logging.warn("bytesSent isn't empty.")

                        let waitingForBody = methodNeedsBody(data) and bodyInTransit(data)
                        if likely(not waitingForBody):
                            for start in parseRequests(data.data):
                                # For pipelined requests, we need to reset this flag.
                                data.headersFinished = true
                                data.requestID = genRequestID()

                                var request = Request(
                                    selector: selector,
                                    client: fd.SocketHandle,
                                    start: start,
                                    requestID: data.requestID,
                                )

                                template validateResponse(): untyped =
                                    if data.requestID == request.requestID:
                                        data.headersFinished = false

                                if validateRequest(request):
                                    data.reqFut = onRequest(request, Response(req: request))
                                    if not data.reqFut.isNil:
                                        data.reqFut.addCallback(
                                            proc (fut: Future[void]) =
                                                onRequestFutureComplete(fut, selector, fd)
                                                validateResponse()
                                        )
                                    else:
                                        validateResponse()

                    if ret != size:
                        # Assume there is nothing else for us right now and break.
                        break
            elif Event.Write in events[i].events:
                assert data.sendQueue.len > 0
                assert data.bytesSent < data.sendQueue.len
                # Write the sendQueue.
                let leftover = data.sendQueue.len-data.bytesSent
                let ret = send(fd.SocketHandle, addr data.sendQueue[data.bytesSent],
                                             leftover, 0)
                if ret == -1:
                    # Error!
                    let lastError = osLastError()
                    if lastError.int32 in {EWOULDBLOCK, EAGAIN}:
                        break
                    if isDisconnectionError({SocketFlag.SafeDisconn}, lastError):
                        handleClientClosure(selector, fd)
                    raiseOSError(lastError)

                data.bytesSent.inc(ret)

                if data.sendQueue.len == data.bytesSent:
                    data.bytesSent = 0
                    data.sendQueue.setLen(0)
                    data.data.setLen(0)
                    selector.updateHandle(fd.SocketHandle, {Event.Read})
            else:
                assert false

proc eventLoop(params: (OnRequest, Application)) =
    let (onRequest, app) = params

    for logger in app.getLoggers:
        addHandler(logger)

    let selector = newSelector[Data]()
    let server = newSocket(app.getDomain)
    server.setSockOpt(OptReuseAddr, true)

    if compileOption("threads") and not app.isRecyclable:
        raise HttpBeastDefect(msg: "--threads:on requires reusePort to be enabled in settings")

    server.setSockOpt(OptReusePort, app.isRecyclable)
    server.bindAddr(app.getPort, app.getAddress)
    server.listen()
    server.getFd().setBlocking(false)
    selector.registerHandle(server.getFd(), {Event.Read}, initData(Server))

    let disp = getGlobalDispatcher()
    selector.registerHandle(getIoHandler(disp).getFd(), {Event.Read}, initData(Dispatcher))

    # Set up timer to get current date/time.
    discard updateDate(0.AsyncFD)
    asyncdispatch.addTimer(1000, false, updateDate)

    var events: array[64, ReadyKey]
    while true:
        let ret = selector.selectInto(-1, events)
        processEvents(selector, events, ret, onRequest)

        # Ensure callbacks list doesn't grow forever in asyncdispatch.
        # @SEE https://github.com/nim-lang/Nim/issues/7532.
        # Not processing callbacks can also lead to exceptions being silently lost!
        if unlikely(asyncdispatch.getGlobalDispatcher().callbacks.len > 0):
            asyncdispatch.poll(0)

#[ API start ]#

proc httpMethod*(req: Request): Option[HttpMethod] {.inline.} =
    ## Parses the request's data to find the request HttpMethod.
    parseHttpMethod(req.selector.getData(req.client).data, req.start)

proc path*(req: Request): Option[string] {.inline.} =
    ## Parses the request's data to find the request target.
    if unlikely(req.client notin req.selector): return
    parsePath(req.selector.getData(req.client).data, req.start)

proc getParams*(req: Request): seq[RoutePatternTuple] =
    ## Retrieve available sequence of RoutePatternTuple for current request
    result = req.params

proc setParams*(req: var Request, params: seq[RoutePatternTuple]) =
    ## Add a sequence of RoutePatternTuple for current request
    req.params = params

proc headers*(req: Request): Option[HttpHeaders] =
    ## Parses the request's data to get the headers.
    if unlikely(req.client notin req.selector):
        return
    parseHeaders(req.selector.getData(req.client).data, req.start)

proc body*(req: Request): Option[string] =
    ## Retrieves the body of the request.
    let pos = req.selector.getData(req.client).headersFinishPos
    if pos == -1: return none(string)
    result = req.selector.getData(req.client).data[pos .. ^1].some()

    when not defined(release):
        let length =
            if req.headers.get().hasKey("Content-Length"):
                req.headers.get()["Content-Length"].parseInt()
            else: 0
        assert result.get().len == length

proc ip*(req: Request): string =
    ## Retrieves the IP address from request
    req.selector.getData(req.client).ip

proc getAgent*(req: Request): string =
    ## Retrieves the user agent from request header
    if req.headers.get().hasKey("user-agent"):
        return req.headers.get()["user-agent"]

proc forget*(req: Request) =
    ## Unregisters the underlying request's client socket from httpbeast's
    ## event loop.
    ##
    ## This is useful when you want to register ``req.client`` in your own
    ## event loop, for example when wanting to integrate httpbeast into a
    ## websocket library.
    assert req.selector.getData(req.client).requestID == req.requestID
    req.selector.unregister(req.client)

proc validateRequest(req: Request): bool =
    ## Handles protocol-mandated responses.
    ##
    ## Returns ``false`` when the request has been handled.
    result = true

    # From RFC7231: "When a request method is received
    # that is unrecognized or not implemented by an origin server, the
    # origin server SHOULD respond with the 501 (Not Implemented) status
    # code."
    if req.httpMethod().isNone():
        req.send(Http501)
        return false

proc run*(onRequest: OnRequest, app: Application) =
    ## Starts the HTTP server and calls `onRequest` for each request.
    ## The ``onRequest`` procedure returns a ``Future[void]`` type. But
    ## unlike most asynchronous procedures in Nim, it can return ``nil``
    ## for better performance, when no async operations are needed.
    # var loadedServices: seq[string] = @["Database", "Cookie", "Http Authentication", "Form Validation"]
    when compileOption("threads"):
        let numThreads = if app.isMultithreading: app.getThreads() else: 1
    else:
        let numThreads = 1

    app.printBootStatus()

    if numThreads == 1:
        eventLoop((onRequest, app))
    else:
        when compileOption("threads"):
            var threads = newSeq[Thread[(OnRequest, Application)]](numThreads)
            for i in 0 ..< numThreads:
                createThread[(OnRequest, Application)](threads[i], eventLoop, (onRequest, app))
            # echo("Listening on port ", settings.port) # This line is used in the tester to signal readiness.
            joinThreads(threads)
        else:
            assert false
