# Supranim is a simple MVC-style web framework for building
# fast web applications, REST API microservices and other cool things.
# 
# The http module is a modified version of httpbeast.
#          (c) Dominik Picheta
#          https://github.com/dom96/httpbeast
#
# (c) 2021 Supranim is released under MIT License
#          
#          Made by Humans from OpenPeep
#          https://supranim.com   |    https://github.com/supranim

import std/[selectors, net, nativesockets, os, httpcore, asyncdispatch,
            strutils, parseutils, options, logging, times, tables]

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
        requestHeaders: Option[HttpHeaders]
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
        deferRedirect: string
            ## Keep a deferred Http redirect from a middleware
        req: Request
            ## Holds the current `Request` instance
        headers: HttpHeaders
            ## All response headers collected from controller

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

const serverInfo = "Supranim" # TODO Support whitelabel signatures

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
                "Content-Length: $#\c\LServer: $#\c\LDate: $#$#\c\L\c\L$#"
            ) % [$code, $body.len, serverInfo, serverDate, otherHeaders, body]

        requestData.sendQueue.add(text)
    req.selector.updateHandle(req.client, {Event.Read, Event.Write})

proc send*(req: Request, code: HttpCode) =
    ## Responds with the specified HttpCode. The body of the response
    ## is the same as the HttpCode description.
    send(req, code, $code)

include ./serve

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

proc newRedirect*(res: var Response, target: string) =
    ## Set a deferred redirect
    res.deferRedirect = target

proc getRedirect*(res: Response): string =
    ## Get a deferred redirect
    res.deferRedirect

proc hasRedirect*(res: Response): bool =
    ## Determine if response should resolve any deferred redirects
    result = res.deferRedirect.len != 0

proc headers*(req: Request): Option[HttpHeaders] =
    ## Parses the request's data to get the headers.
    if unlikely(req.client notin req.selector):
        return
    parseHeaders(req.selector.getData(req.client).data, req.start)

proc hasHeaders*(req: Request): bool =
    result = req.requestHeaders.get() != nil

proc getHeader*(req: Request, key: string): string = 
    let headers = req.requestHeaders.get()
    if headers.hasKey(key):
        result = headers[key]

method addHeader*[R: Response](res: var R, key, value: string) {.base.} =
    ## Add a new header value to current `Response` instance
    res.headers.add(key, value)

method getHeaders*[R: Response](res: R, default: string): string {.base.} =
    ## Return the current current stringified `Response` Headers
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
