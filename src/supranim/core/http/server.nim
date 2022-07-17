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

from std/strutils import indent
from std/sugar import capture
from std/json import JsonNode, `$`
from std/deques import len

when defined(windows):
    import std/sets
    import std/monotimes
    import std/heapqueue
else:
    import std/posix
    from std/osproc import countProcessors

import ../application

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

    Param = tuple[k, v: string]
        ## Key-Value tuple used to handle GET request parameters

    HeaderValue* = object
        value: string

    Request* = object
        selector: Selector[Data]
        client*: SocketHandle
            # Determines where in the data buffer this request starts.
            # Only used for HTTP pipelining.
        start: int
            # Identifier used to distinguish requests.
        requestID*: uint
            # Identifier for current request
        patterns: seq[RoutePatternRequest]
            ## Holds all route patterns from current request
        params: seq[Param]
            ## Holds all GET parameters from current request
        reqHeaders: Option[HttpHeaders]
            ## Holds all headers from current request
        ip: string
            ## The public IP address from request
        methodType: HttpMethod
            ## The ``HttpMethod`` of the request

    CacheControlResponse* = enum
        ## The Cache-Control HTTP header field holds directives (instructions)
        ## in both requests and responses — that control caching in browsers
        ## and shared caches (e.g. Proxies, CDNs).
        ## https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Cache-Control
        MaxAge = "max-age"
            ## The max-age=N response directive indicates that the response
            ## remains fresh until N seconds after the response is generated.
        SMaxAge = "s-maxage"
            ## The s-maxage response directive also indicates how long the
            ## response is fresh for (similar to max-age) — but it is specific
            ## to shared caches, and they will ignore max-age when it is present
        NoCache = "no-cache"
            ## The no-cache response directive indicates that the response can be
            ## stored in caches, but the response must be validated with the origin
            ## server before each reuse, even when the cache is disconnected from
            ## the origin server.
        NoStore = "no-store"
            ## The no-store response directive indicates that any caches of any
            ## kind (private or shared) should not store this response.
        NoTransform = "no-transform"
            ## Some intermediaries transform content for various reasons.
            ## For example, some convert images to reduce transfer size.
            ## In some cases, this is undesirable for the content provider.
        MustRevalidate = "must-revalidate"
            ## The must-revalidate response directive indicates that the response can
            ## be stored in caches and can be reused while fresh. If the response
            ## becomes stale, it must be validated with the origin server before reuse.
        ProxyRevalidate = "proxy-revalidate"
            ## The proxy-revalidate response directive is the equivalent of
            ## must-revalidate, but specifically for shared caches only.
        MustUnderstand = "must-understand"
            ## The must-understand response directive indicates that a cache should
            ## store the response only if it understands the requirements for caching
            ## based on status code.
        Private = "private"
            ## The private response directive indicates that the response can be
            ## stored only in a private cache (e.g. local caches in browsers).
        Public = "public"
            ## The public response directive indicates that the response can be stored
            ## in a shared cache. Responses for requests with Authorization header fields
            ## must not be stored in a shared cache; however, the public directive will
            ## cause such responses to be stored in a shared cache.
        Immutable = "immutable"
            ## The immutable response directive indicates that the response will
            ## not be updated while it's fresh.
        StaleWhileRevalidate = "stale-while-revalidate"
            ## The stale-while-revalidate response directive indicates that the
            ## cache could reuse a stale response while it revalidates it to a cache.
        StaleIfError = "stale-if-error"
            ## The stale-if-error response directive indicates that the cache can
            ## reuse a stale response when an origin server responds with an error
            ## (500, 502, 503, or 504).

    Response* = object
        deferRedirect: string           ## Keep a deferred Http redirect from a middleware
        req: Request                    ## Holds the current `Request` instance
        headers: HttpHeaders            ## All response headers collected from controller
        session: SessionInstance

    OnRequest* = proc (req: var Request, res: var Response, app: Application): Future[void] {.gcsafe.}
        ## Procedure used on request

    SupranimDefect* = ref object of Defect
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

var serverDate {.threadvar.}: string

proc updateDate(fd: AsyncFD): bool =
    result = false # Returning true signifies we want timer to stop.
    serverDate = now().utc().format("ddd, dd MMM yyyy HH:mm:ss 'GMT'")

template withRequestData(req: Request, body: untyped) =
    let requestData {.inject.} = addr req.selector.getData(req.client)
    body

proc getRequest*(res: Response): Request =
    ## Returns the current Request instance
    result = res.req

#
# Response Handler
#
proc unsafeSend*(req: Request, data: string) =
    ## Sends the specified data on the request socket.
    ##
    ## This function can be called as many times as necessary.
    ##
    ## It does not check whether the socket is in
    ## a state that can be written so be careful when using it.
    if req.client notin req.selector:
        return
    withRequestData(req):
        requestData.sendQueue.add(data)
    req.selector.updateHandle(req.client, {Event.Read, Event.Write})

proc send*(req: Request, code: HttpCode, body: string, headers="") =
    ## Responds with the specified HttpCode and body.
    ## **Warning:** This can only be called once in the OnRequest callback.
    if req.client notin req.selector:
        return

    withRequestData(req):
        # assert requestData.headersFinished, "Selector not ready to send."
        if requestData.requestID != req.requestID:
            raise SupranimDefect(msg: "You are attempting to send data to a stale request.")

        let otherHeaders = if likely(headers.len == 0): "" else: "\c\L" & headers
        var
            text = (
                "HTTP/1.1 $#\c\L" &
                "Content-Length: $#\c\LDate: $#$#\c\L\c\L$#"
            ) % [$code, $body.len, serverDate, otherHeaders, body]

        requestData.sendQueue.add(text)
    req.selector.updateHandle(req.client, {Event.Read, Event.Write})

proc send*(req: Request, code: HttpCode) =
    ## Responds with the specified HttpCode. The body of the response
    ## is the same as the HttpCode description.
    send(req, code, $code)

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

var requestCounter: uint = 0
proc genRequestID(): uint =
    if requestCounter == high(uint):
        requestCounter = 0
    requestCounter += 1
    return requestCounter

proc validateRequest(req: Request): bool {.gcsafe.}


#
# Request API
#
method hasHeaders*(req: Request): bool =
    ## Determine if current Request instance has any headers
    result = req.reqHeaders.get() != nil

proc hasHeaders*(headers: Option[HttpHeaders]): bool =
    ## Checks for existing headers for given `Option[HttpHeaders]`
    result = headers.get() != nil

method getHeaders*(req: Request): Option[HttpHeaders] =
    ## Returns all `HttpHeaders` from current `Request` instance
    result = req.reqHeaders

method hasHeader*(req: Request, key: string): bool =
    ## Determine if current Request instance has a specific header
    result = req.reqHeaders.get().hasKey(key)

proc hasHeader*(headers: Option[HttpHeaders], key: string): bool =
    ## Determine if current `Request` intance contains a specific header by `key`
    result = headers.get().hasKey(key)

method getHeader*(req: Request, key: string): string = 
    ## Retrieves a specific header from given `Option[HttpHeaders]`
    let headers = req.reqHeaders.get()
    if headers.hasKey(key):
        result = headers[key]

proc getHeader*(headers: Option[HttpHeaders], key: string): string = 
    ## Retrieves a specific header from given `Option[HttpHeaders]`
    if headers.hasHeader(key): result = headers.get()[key]

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
        for i in 0 ..< ret: data.data[origLen+i] = buf[i]

        if fastHeadersCheck(data) or slowHeadersCheck(data):
            # First line and headers for request received.
            data.headersFinished = true
            when not defined(release):
                if data.sendQueue.len != 0:
                    logging.warn("sendQueue isn't empty.")
                if data.bytesSent != 0:
                    logging.warn("bytesSent isn't empty.")

            # let m = parseHttpMethod(data.data, start=0);
            # let waitingForBody = methodNeedsBody(data) and bodyInTransit(data)
            let waitingForBody = false
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
                        # Once validated, initialize a new Response object
                        # to be sent together with Headers and a Session ID.
                        let reqHeaders = req.getHeaders()
                        # let clientPlatform = reqHeaders.getHeader("sec-ch-ua-platform")
                        # let clientIsMobile = reqHeaders.getHeader("sec-ch-ua-mobile") == "true"
                        var res = Response(req: req, headers: newHttpHeaders())
                        # res.session = Session.newSession((
                        #     cookies: reqHeaders.getHeader("Cookie"),
                        #     agent: reqHeaders.getHeader("user-agent"),
                        #     os: clientPlatform,
                        #     mobile: clientIsMobile and clientPlatform in ["Android", "iOS"]
                        # ))
                        # for k, cookie in mpairs(res.session.getCookies):
                        #     res.headers.add("set-cookie", $cookie)

                        data.reqFut = onRequest(req, res, app)
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

proc processEvents(selector: Selector[Data], events: array[64, ReadyKey], count: int, onRequest: OnRequest, app: Application) =
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
            else:
                assert false, "Only Read events are expected for the server"
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
            else: assert false

proc eventLoop(params: (OnRequest, Application)) =
    let (onRequest, app) = params

    for logger in app.getLoggers:
        addHandler(logger)

    let selector = newSelector[Data]()
    let server = newSocket(app.getDomain)
    server.setSockOpt(OptReuseAddr, true)

    if compileOption("threads") and not app.isRecyclable:
        raise SupranimDefect(msg: "--threads:on requires reusePort to be enabled in settings")

    server.setSockOpt(OptReusePort, app.isRecyclable)
    server.bindAddr(app.getPort, app.getAddress)
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
            processEvents(selector, events, ret, onRequest, app)
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
                processEvents(selector, events, ret, onRequest, app)
            asyncdispatch.poll(0)

#[ API start ]#

proc httpMethod*(req: Request): Option[HttpMethod] =
    ## Parses the request's data to find the request HttpMethod.
    result = parseHttpMethod(req.selector.getData(req.client).data, req.start)

proc path*(req: Request): Option[string] =
    ## Parses the request's data to find the request target.
    if unlikely(req.client notin req.selector): return
    result = parsePath(req.selector.getData(req.client).data, req.start)

proc getCurrentPath*(req: Request): string = 
    ## Alias for retrieving the route path from current request
    result = req.path().get()
    if result[0] == '/':
        result = result[1 .. ^1]

proc isPage*(req: Request, key: string): bool =
    ## Determine if current page is as expected
    result = req.getCurrentPath() == key

proc getParams*(req: Request): seq[RoutePatternRequest] =
    ## Retrieves all dynamic patterns (key/value)
    ## from current request
    result = req.patterns

proc hasParams*(req: Request): bool =
    ## Determine if the current request contains
    ## any parameters from the dynamic route
    result = req.patterns.len != 0

proc setParams*(req: var Request, reqValues: seq[RoutePatternRequest]) =
    ## Map values from request to route parameters
    ## Add dynamic route values from current request 
    for reqVal in reqValues:
        req.patterns.add(reqVal)

method newRedirect*(res: var Response, target: string) =
    ## Set a deferred redirect
    res.deferRedirect = target

method getRedirect*(res: Response): string =
    ## Get a deferred redirect
    res.deferRedirect

method getSessionInstance*(res: Response): SessionInstance =
    result = res.session

method hasRedirect*(res: Response): bool =
    ## Determine if response should resolve any deferred redirects
    result = res.deferRedirect.len != 0

method headers*(req: Request): Option[HttpHeaders] =
    ## Parses the request's data to get the headers.
    if unlikely(req.client notin req.selector):
        return
    parseHeaders(req.selector.getData(req.client).data, req.start)

method addHeader*(res: var Response, key, value: string) =
    ## Add a new Response Header to given instance.
    res.headers.add(key, value)

method getHeaders*(res: Response, default: string): string =
    ## Returns the stringified HTTP Headers of `Response` instance
    if res.headers.len != 0:
        for h in res.headers.pairs():
            result &= h.key & ":" & indent(h.value, 1)
    else: result = default

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

# proc ip*(req: Request): string =
#     ## Retrieves the IP address from request
#     req.selector.getData(req.client).ip

proc forget*(req: Request) =
    ## Unregisters the underlying request's client socket from event loop.
    ##
    ## This is useful when you want to register ``req.client`` in your own
    ## event loop, for example when wanting to integrate the server into a
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
    app.printBootStatus()
    when compileOption("threads"):
        if app.isMultithreading:
            var threads = newSeq[Thread[(OnRequest, Application)]](app.getThreads)
            for i in 0 ..< app.getThreads:
                createThread[(OnRequest, Application)](threads[i], eventLoop, (onRequest, app))
            joinThreads(threads)
        else: eventLoop((onRequest, app))
    else:
        eventLoop((onRequest, app))
