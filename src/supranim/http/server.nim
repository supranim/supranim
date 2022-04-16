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
from std/json import JsonNode, `$`

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

    Param = tuple[k, v: string]
        ## Key-Value tuple used to handle GET request parameters

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

    Response* = object
        req: Request
            ## Holds a Request object instance of the current response

    OnRequest* = proc (req: var Request, res: var Response, app: Application): Future[void] {.gcsafe.}
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
include ./serve

#[ API start ]#

proc httpMethod*(req: Request): Option[HttpMethod] {.inline.} =
    ## Parses the request's data to find the request HttpMethod.
    parseHttpMethod(req.selector.getData(req.client).data, req.start)

proc path*(req: Request): Option[string] {.inline.} =
    ## Parses the request's data to find the request target.
    if unlikely(req.client notin req.selector): return
    parsePath(req.selector.getData(req.client).data, req.start)

proc getCurrentPath*(req: Request): string = 
    ## Alias for retrieving the route path from current request
    result = req.path().get()
    if result[0] == '/':
        result = result[1 .. ^1]

proc isPage*(req: Request, key: string): bool =
    ## Determine if current page is as expected
    result = req.getCurrentPath() == key

proc getParams*(req: Request): seq[RoutePatternRequest] =
    ## Retrieves all dynamic patterns (key/value) from current request
    result = req.patterns

proc hasParams*(req: Request): bool =
    ## Determine if the current request contains any parameters from the dynamic route
    result = req.patterns.len != 0

proc setParams*(req: var Request, reqValues: seq[RoutePatternRequest]) =
    ## Map values from request to route parameters
    ## Add dynamic route values from current request 
    for reqVal in reqValues:
        req.patterns.add(reqVal)

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
    let headers = req.headers.get()
    if headers.hasKey("user-agent"):
        result = headers["user-agent"]

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
    const compiledWithThreads = compileOption("threads")
    var numThreads = 1
    when compiledWithThreads:
        numThreads = if app.isMultithreading: app.getThreads() else: numThreads
    app.printBootStatus()
    if numThreads == 1:
        eventLoop((onRequest, app))
    else:
        when compiledWithThreads:
            var threads = newSeq[Thread[(OnRequest, Application)]](numThreads)
            for i in 0 ..< numThreads:
                createThread[(OnRequest, Application)](threads[i], eventLoop, (onRequest, app))
            # echo("Listening on port ", settings.port) # This line is used in the tester to signal readiness.
            joinThreads(threads)
        else:
            assert false
