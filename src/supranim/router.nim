import std/tables

from std/times import DateTime
from std/options import Option
from std/enumutils import symbolName
from std/strutils import `%`

from ./server import HttpMethod, Request, Response

export HttpMethod

type
    Callable* = proc(req: Request, res: Response) {.nimcall.}
    MiddlewareFunction = proc(req: Request)

    Middleware* = object
        name*: string
        callable*: proc(req: Request): void {.gcsafe.}

    Pattern* = enum
        Id, Slug, Date

    Route* = object
        path: string
        verb: HttpMethod
        callback: Callable
        case hasMiddleware: bool
        of true:
            middleware: seq[tuple[id: string, callable: Middleware]]
        else: discard
        case isTemporary: bool
        of true:
            expiration: Option[DateTime]
        else: discard

    VerbCollection = Table[string, Route]
    GroupRouteTuple* = tuple[verb: HttpMethod, route: string, callback: Callable]

    RouterHandler = object
        httpGet, httpPost, httpPut, httpHead, httpConnect: VerbCollection
        httpDelete, httpPatch, httpTrace, httpOptions: VerbCollection

    RouterException* = object of CatchableError

var Router* = RouterHandler()

proc register[R: RouterHandler](router: var R, verb: HttpMethod, route: Route) =
    ## Register a new route by given Verb and Route object
    case verb:
        of HttpGet:      router.httpGet[route.path] = route
        of HttpPost:     router.httpPost[route.path] = route
        of HttpPut:      router.httpPut[route.path] = route
        of HttpHead:     router.httpHead[route.path] = route
        of HttpConnect:  router.httpConnect[route.path] = route
        of HttpDelete:   router.httpDelete[route.path] = route
        of HttpPatch:    router.httpPatch[route.path] = route
        of HttpTrace:    router.httpTrace[route.path] = route
        of HttpOptions:  router.httpOptions[route.path] = route

proc getCollectionByVerb[R: RouterHandler](router: var R, verb: HttpMethod): VerbCollection  =
    ## Get `VerbCollection`, `Table[string, Route]` based on given verb
    result = case verb:
        of HttpGet:     router.httpGet
        of HttpPost:    router.httpPost
        of HttpPut:     router.httpPut
        of HttpHead:    router.httpHead
        of HttpConnect: router.httpConnect
        of HttpDelete:  router.httpDelete
        of HttpPatch:   router.httpPatch
        of HttpTrace:   router.httpTrace
        of HttpOptions: router.httpOptions

proc exists[R: RouterHandler](router: var R, verb: HttpMethod, path: string): bool =
    ## Determine if route exists for given `key/path` based on verb
    let collection = router.getCollectionByVerb(verb)
    result = collection.hasKey(path)

proc getExists*[R: RouterHandler](router: var R, path: string): bool =
    ## Determine if there is a registered route in HttpGet collection for given key
    result = router.exists(HttpGet, path)

proc getRoute*[R: RouterHandler](router: var R, path: string): Route =
    ## Retrieve a HttpGet route from RouterHandler collections
    result = router.httpGet[path]

proc isTemporary*[R: RouterHandler](router: R, verb: HttpMethod, path: string): bool =
    ## Determine if specified route has expiration time
    let collection = getCollectionByVerb(verb)
    result = collection[path].isTemporary

proc runCallable*[R: Route](route: R, req: Request, res: Response) =
    ## Run callable from route controller
    route.callback(req, res)

proc middleware*[R: Route](route: var R, middlewares: seq[tuple[id: string, callable: proc(req: Request): void {.gcsafe.}]]) =
    ## Set one or more middleware handlers to current Route
    route.hasMiddleware = true
    route.middleware = middlewares

proc expire*[R: Route](route: var R, expiration: Option[DateTime]) =
    ## Set expiration time for current Route
    discard

proc get*[R: RouterHandler](router: var R, path: string, callback: proc(req: Request, res: Response): void {.gcsafe.}): Route {.discardable.} = 
    ## Register a new route for `HttpGet` method
    router.register(HttpGet, Route(path: path, verb: HttpGet, callback: callback))
    result = router.httpGet[path]

proc post*[R: RouterHandler](router: var R, path: string, callback: proc(req: Request, res: Response): void {.gcsafe.}): Route {.discardable.} = 
    ## Register a new route for `HttpPost` method
    router.register(HttpPost, Route(path: path, verb: HttpPost, callback: callback))
    result = router.httpPost[path]

proc put*[R: RouterHandler](router: var R, path: string, callback: proc(req: Request, res: Response): void {.gcsafe.}): Route {.discardable.} = 
    ## Register a new route for `HttpPut` method
    router.register(HttpPut, Route(path: path, verb: HttpPut, callback: callback))
    result = router.httpPut[path]

proc head*[R: RouterHandler](router: var R, path: string, callback: proc(req: Request, res: Response): void {.gcsafe.}): Route {.discardable.} = 
    ## Register a new route for `HttpHead` method
    router.register(HttpHead, Route(path: path, verb: HttpHead, callback: callback))
    result = router.httpHead[path]

proc connect*[R: RouterHandler](router: var R, path: string, callback: proc(req: Request, res: Response): void {.gcsafe.}): Route {.discardable.} = 
    ## Register a new route for `HttpConnect` method
    router.register(HttpConnect, Route(path: path, verb: HttpConnect, callback: callback))
    result = router.httpConnect[path]

proc delete*[R: RouterHandler](router: var R, path: string, callback: proc(req: Request, res: Response): void {.gcsafe.}): Route {.discardable.} = 
    ## Register a new route for `HttpDelete` method
    router.register(HttpDelete, Route(path: path, verb: HttpDelete, callback: callback))
    result = router.httpDelete[path]

proc patch*[R: RouterHandler](router: var R, path: string, callback: proc(req: Request, res: Response): void {.gcsafe.}): Route {.discardable.} = 
    ## Register a new route for `HttpPatch` method
    router.register(HttpPatch, Route(path: path, verb: HttpPatch, callback: callback))
    result = router.httpPatch[path]

proc unique*[R: RouterHandler](router: var R, verb: HttpMethod, callback: proc(req: Request, res: Response): void {.gcsafe.}): Route {.discardable.} =
    ## Generate unique route for specified verb
    discard

proc group*[R: RouterHandler](router: var R, basePath: string, routes: varargs[GroupRouteTuple]): RouterHandler {.discardable.} =
    ## Add group of routes. Handy when adding multiple
    ## routes at once, under same base URI, and optionally,
    ## protected by one or more middleware handlers
    for r in routes:
        let routePath = if r.route == "/": basePath else: basePath  & "/" & r.route
        if not router.exists(r.verb, routePath):
            router.register(r.verb, Route(path: routePath, verb: r.verb, callback: r.callback))
        else:
            raise newException(RouterException,
                "Duplicate route for \"$1\" path of $2" % [r.route, symbolName(r.verb)])
    result = router
