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
        sessionId: Uuid                 ## An `UUID` representing the current `UserSession`

    OnRequest* = proc (req: var Request, res: var Response): Future[void] {.gcsafe.}
        ## Procedure used on request

    AppConfig = tuple[onRequest: OnRequest, domain: Domain, address: string, port: Port, isReusable: bool]

    SupranimDefect* = ref object of Defect
        ## Catchable object error

    RoutePattern* = enum
        ## Base route patterns
        None, Id, Slug, Alpha, Digits, Date, DateYear, DateMonth, DateDay

    RoutePatternTuple* = tuple[pattern: RoutePattern, str: string, optional, dynamic: bool]
        ## RoutePattern tuple is used for all Route object instances.
        ## Holds the pattern representation of each path, where
        ## ``pattern`` is one from Pattern enum,

    RoutePatternRequest* = tuple[pattern: RoutePattern, str: string]
        ## Similar to ``RoutePatternTuple``, the only difference is that is used
        ## during runtime for parsing each path request.

var serverDate {.threadvar.}: string
