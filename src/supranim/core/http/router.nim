# Supranim is a simple MVC-style web framework for building
# fast web applications, REST API microservices and other cool things.
#
# (c) 2021 Supranim is released under MIT License
#          George Lemon | Made by Humans from OpenPeep
#          https://supranim.com   |    https://github.com/supranim

import std/[tables, macros, with]

from std/times import DateTime
from std/options import Option
from std/sequtils import toSeq
from std/enumutils import symbolName

from std/strutils import `%`, split, isAlphaNumeric, isAlphaAscii, isDigit,
                        startsWith, toUpperAscii, contains

from ./server import HttpMethod, Request, Response, RoutePattern,
                    RoutePatternTuple, RoutePatternRequest, HttpCode, shouldRedirect

when not defined release:
    # Register a dev-only route for hot code reloading support.
    # See method `initLiveReload` at the bottom of this file
    import jsony
    import std/[times, json]
    from ./server import json

export HttpMethod, Response, Request, HttpCode

type
    Callable* = proc(req: Request, res: var Response) {.nimcall.}
        ## Callable procedure for route controllers

    Middleware* = proc(res: var Response): bool {.nimcall.}
        ## A callable Middleware procedure

    RouteType = enum
        ## Define available route types, it can be either static,
        ## or dynamic (when using Route patterns)
        StaticRouteType, DynamicRouteType

    ControllerByVerb = enum
        getController = "get$1"
        postController = "post$1"
        putController = "put$1"
        headController = "head$1"
        deleteController = "delete$1"
        connectController = "connect$1"
        optionsController = "options$1"
        traceController = "trace$1"
        patchController = "patch$"

    RouteStatus* = enum
        NotFound, Found, BlockedByAbort, BlockedByRedirect

    Route* = object
        ## Route object used to manage application routes
        path: string
            ## Determine if current Route instance contains any Pattern
        verb: HttpMethod
            ## Holds the HttpMethod, either HttpGet, HttPost and so on
        case routeType: RouteType
            ## Each Route object has a routeType which can be either
            ## StaticRouteType or DynamicRouteType.
            of DynamicRouteType:
                patterns: seq[RoutePatternTuple]
                    ## Holds a sequence of RoutePatternTuple for entire path,
                    ## in order (from left to right)
                params: seq[RoutePatternTuple]
                    ## Holds a seq of RoutePatternTuple for dynamic patterns only
                    ## (in order, from left to right).
                    ## Params can be later used in controller based procedure
                    ## to retrieve the pattern value from request
            else: discard
        callback: Callable
        case hasMiddleware: bool
            ## Determine if current Route object has one or
            ## more middleware attached to it.
            of true:
                middlewares: seq[Middleware]
                    ## A sequence of Middlewares. Note that middlewares
                    ## are always checked in the same order that have been provided.
            else: discard

    RuntimeRouteStatus* = tuple[
        status: RouteStatus,
        key: string,
        params: seq[RoutePatternRequest],
        route: ref Route
    ]

    VerbCollection* = TableRef[string, ref Route]
        ## ``VerbCollection``, is a table that contains Route Objects stored by their path
        ## Note that, each ``HttpMethod`` has its own collection.
        ## Also, based on their ``routeType``, route objects can be
        ## stored either in ``httpGet`` or ``httpGetDynam``
    GroupRouteTuple* = tuple[verb: HttpMethod, route: string, callback: Callable]

    ErrorPagesTable = Table[int, proc(): string]
    HttpRouter = object
        ## Router Handler that holds all VerbCollection tables Table[string, Route]
        httpGet, httpPost, httpPut, httpHead, httpConnect: VerbCollection
        httpDelete, httpPatch, httpTrace, httpOptions: VerbCollection
            ## VerbCollection reserved for all static routes (routes without specific patterns)
        httpGetDynam, httpPostDynam, httpPutDynam, httpHeadDynam, httpConnectDynam: VerbCollection
        httpDeleteDynam, httpPatchDynam, httpTraceDynam, httpOptionsDynam: VerbCollection
            ## VerbCollection reserved for dynamic routes (routes containing patterns)

    RouterException* = object of CatchableError
        ## Catchable Router Exception

proc setField[T: VerbCollection](k: string, val: var T) =
    val = newTable[string, ref Route]()

template initTables(router: object): untyped =
    block fieldFound:
        for k, v in fieldPairs(router):
            setField(k, v)

proc initCollectionTables*(router: var HttpRouter) = router.initTables()

# when compileOption("threads"):
#     var Router* {.threadvar.}: HttpRouter
#     var ErrorPages* {.threadvar.}: ErrorPagesTable
# else:
var Router*: HttpRouter
var ErrorPages*: ErrorPagesTable

Router = HttpRouter()
Router.initCollectionTables()   # https://forum.nim-lang.org/t/5631#34992

# proc init*(router: var HttpRouter) =
#     Router = HttpRouter()
#     Router.initCollectionTables()   # https://forum.nim-lang.org/t/5631#34992

proc isDynamic*[R: Route](route: ref R): bool =
    ## Determine if current routeType of route object instance is type of ``DynamicRouteType``
    result = route.routeType == DynamicRouteType

macro getCollection(router: object, field: string, hasParams: bool): untyped =
    ## Retrieve a Collection of routes from ``RouterHandler``
    result = nnkStmtList.newTree()
    result.add(
        nnkIfStmt.newTree(
            nnkElifBranch.newTree(
                nnkInfix.newTree(
                    newIdentNode("=="),
                    newIdentNode(hasParams.strVal),
                    newIdentNode("true")
                ),
                nnkStmtList.newTree(
                    newDotExpr(router, newIdentNode(field.strVal & "Dynam"))
                )
            ),
            nnkElse.newTree(
                nnkStmtList.newTree(
                    newDotExpr(router, newIdentNode(field.strVal))
                )
            )
        )
    )

method getCollectionByVerb(router: var HttpRouter, verb: HttpMethod, hasParams = false): VerbCollection  =
    ## Get `VerbCollection`, `Table[string, Route]` based on given verb
    result = case verb:
        of HttpGet:     router.getCollection("httpGet", hasParams)
        of HttpPost:    router.getCollection("httpPost", hasParams)
        of HttpPut:     router.getCollection("httpPut", hasParams)
        of HttpHead:    router.getCollection("httpHead", hasParams)
        of HttpConnect: router.getCollection("httpConnect", hasParams)
        of HttpDelete:  router.getCollection("httpDelete", hasParams)
        of HttpPatch:   router.getCollection("httpPatch", hasParams)
        of HttpTrace:   router.getCollection("httpTrace", hasParams)
        of HttpOptions: router.getCollection("httpOptions", hasParams)

method register(router: var HttpRouter, verb: HttpMethod, route: ref Route) =
    ## Register a new route by given Verb and Route object
    router.getCollectionByVerb(verb, route.routeType == DynamicRouteType)[route.path] = route

proc getPatternsByStr(path: string): seq[RoutePatternRequest] =
    ## Create a sequence of RoutePattern for requested path.
    let pathSeq: seq[string] = path.split("/")
    for pathStr in pathSeq:
        if pathStr.len == 0: continue
        var pattern: RoutePattern
        for pathSeqChar in pathStr.toSeq:
            if isDigit(pathSeqChar):
                if pattern == Slug:
                    discard # set as `Slug` if already contains alpha ascii
                else:
                    pattern = Id
            elif isAlphanumeric(pathSeqChar):
                pattern = Slug
            elif isAlphaAscii(pathSeqChar):
                pattern = Alpha
        result.add((pattern: pattern, str: pathStr))
        pattern = None

proc getPattern(curr, str: string, opt, dynamic = false): RoutePatternTuple =
    ## Create a RoutePattern based on given string pattern containing:
    ## ``tuple[pattern: Pattern, str: string, optional: bool]``
    ## - ``pattern`` field must be an item from Pattern enum,
    ## - ``str`` field is auto filled if route is statically declared,
    ## - ``opt`` if pattern should be considered optional.
    var pattern: RoutePattern
    case curr:
        of "id":
            pattern = Id            # accepts max 64 length Digits only (no hyphen)
        of "slug":
            pattern = Slug          # ASCII mix between Alpha, Digits separated by Hyphen
        of "alpha":
            pattern = Alpha         # accepts only [A..Z][a..z]
        of "digit":
            pattern = Digits        # accepts only digits 0..9
        of "date":
            pattern = Date          # a group of DateYear-DateMonth-DateDay separated by Hyphen 
        of "year":
            pattern = DateYear      # accepts only 4 group numbers, like 1995, 2022
        of "month":
            pattern = DateMonth     # accepts only numbers from 1 to 12
        of "day":
            pattern = DateDay       # accepts only numbers from 1 to 31
        else:
            for currChar in curr.toSeq:
                if isDigit(currChar):
                    if pattern == Slug: discard
                    else: pattern = Id
                elif isAlphanumeric(currChar):  pattern = Slug
                elif isAlphaAscii(currChar):    pattern = Alpha
    result = (pattern: pattern, str: str, optional: opt, dynamic: dynamic)

proc parseRoutePath(path: string): tuple[routeType: RouteType, patterns: seq[RoutePatternTuple]] =
    var
        patterns: seq[RoutePatternTuple]
        routeType: RouteType
    for pathItem in split(path, "/"):
        var
            i = 0
            currp: string
            startp, endp: bool
            isOpt, isOptChar, isPattern: bool
        if pathItem.len == 0:                   # skip if empty
            continue
        let pathSeq = toSeq(pathItem)
        for pathChar in pathSeq:
            if pathChar == '{':                 # handle start of pattern
                if startp == true:
                    raise newException(RouterException, "Missing closing route pattern")
                isPattern = true
                startp = true
                endp = false
                if pathSeq[i + 1] == '?':
                    isOpt = true
                    isOptChar = true
            elif pathChar == '}':               # handle end of pattern
                if startp == false:
                    raise newException(RouterException, "Missing opening route pattern")
                patterns.add(getPattern(currp, "", isOpt, true))
                isPattern = false
                endp = true
                startp = false
                setLen currp, 0
                routeType = DynamicRouteType
            else:
                if startp == true and endp == false:
                    if not isOptChar:
                        currp.add pathChar
                elif startp == false and endp == false:
                    startp = false
                    currp.add pathChar
                isOptChar = false
            inc i
        if not isPattern and currp.len != 0:
            patterns.add(getPattern(pathItem, currp))
    result = (routeType: routeType, patterns: patterns)

proc parseRoute(path: string, verb: HttpMethod, callback: Callable): ref Route =
    ## Parse route by path string, verb, callback and
    ## return a Route object instance for registration.
    ##
    ## Supranim Router can handle dynamic routes using one or
    ## more Route Patterns as ``{id}`` - (64bit long Digits),
    ## ``{slug}`` - (alphanumerical separated by hyphen) and so on
    ##
    ## All patterns are by default required.
    ## For making an optional route pattern you must add a question mark
    ## inside the pattern. For example ``{?slug}``
    let routePattern = parseRoutePath(path)
    result = new Route
    if routePattern.routeType == DynamicRouteType:
        # determine if routeType is DynamicRouteType, which
        # in this case route object should contain dymamic patterns.
        with result:
            path = path
            verb = verb
            routeType = DynamicRouteType
            callback = callback
        result.patterns = routePattern.patterns
        for pattern in result.patterns:
            # find dynamic patterns and store in separate field
            # as params for later use on request in controller-based procedures
            if pattern.dynamic:
                result.params.add(pattern)
    else:
        with result:
            path = path
            verb = verb
            routeType = StaticRouteType
            callback = callback

proc getNameByPath(route: string): string {.compileTime.} =
    # A compile time procedure to generate controller names
    # based on the linked route.
    # 
    # For example if your route is
    # ```Router.get("/")```
    # Then, the controller will be
    # ```proc getHomepage(req: Request, res: var Response) =```
    # 
    # Also, if a route is
    # ```Router.get("/users")
    # The controller name will be 
    # ```proc getUsers(req: Request, res: var Response) =```
    # 
    # TODO
    # Support controller generation name for routes
    # that contains dynamic patterns as `{id}`, `{slug}` and so on.
    # where a route like `/users/{id}/edit` will look
    # for a controller named `getUsersByIdEdit`
    if route == "/": return "Homepage"
    var paths =
        if route[0] == '/':
            split(route[1 .. ^1], {'/', '-'})
        else: split(route, {'/', '-'})
    for path in paths:
        result &= toUpperAscii(path[0])
        result &= path[1 .. ^1]

proc initControllerName(methodType: HttpMethod, path: string): string {.compileTime.} =
    case methodType:
    of HttpGet:     result = $getController
    of HttpPost:    result = $postController
    of HttpPut:     result = $putController
    of HttpHead:    result = $headController
    of HttpConnect: result = $connectController
    of HttpDelete:  result = $deleteController
    of HttpPatch:   result = $deleteController
    of HttpTrace:   result = $traceController
    of HttpOptions: result = $optionsController
    result = result % [getNameByPath(path)]

proc exists*[R: HttpRouter](router: var R, verb: HttpMethod, path: string): bool =
    ## Determine if requested route exists for given `HttpMethod`
    let collection = router.getCollectionByVerb(verb)
    result = collection.hasKey(path)

proc runtimeExists*(router: var HttpRouter, verb: HttpMethod, path: string,
                    req: Request, res: var Response): RuntimeRouteStatus =
    let staticRoutes = router.getCollectionByVerb(verb)
    try:
        result.route = staticRoutes[path]
        if result.route.hasMiddleware:
            for middlewareCallback in result.route.middlewares:
                let status = middlewareCallback(res)
                if status == false:
                    if res.shouldRedirect():
                        result.status = BlockedByRedirect
                    else:
                        result.status = BlockedByAbort
                    return
        result.status = Found
    except ValueError:
        let dynamicRoutes = router.getCollectionByVerb(verb, true)
        var reqPattern = getPatternsByStr(path)
        var matchRoutePattern: bool
        var reqPatternKeys: seq[int]
        for key, route in dynamicRoutes.pairs():
            let routePatternsLen = route.patterns.len
            let reqPatternsLen = reqPattern.len
            # TODO handle optional patterns
            if routePatternsLen != reqPatternsLen:
                continue
            else: 
                var i = 0
                while true:
                    if i == routePatternsLen: break
                    if reqPattern[i].pattern == route.patterns[i].pattern:
                        matchRoutePattern = true
                        if not route.patterns[i].dynamic:               # store all non dynamic route patterns.
                            reqPatternKeys.add(i)
                        else:
                            reqPattern[i].str = reqPattern[i].str
                    else:
                        matchRoutePattern = false
                        break
                    inc i
            if matchRoutePattern:
                result.status = Found
                result.key = route.path
                result.route = route
                for reqPatternKey in reqPatternKeys:
                    # delete all non dynamic pattern by index key.
                    # in this way `reqPattern` will contain only dynamic patterns that
                    # need to be exposed in controlled-based procedure to retrieve values.
                    reqPattern.del(reqPatternKey)
                result.params = reqPattern
                break
            else:
                result.status = NotFound
                break

proc runCallable*[R: Route](route: ref R, req: var Request, res: var Response) =
    ## Run callable from route controller
    route.callback(req, res)

proc expire*[R: Route](route: var R, expiration: Option[DateTime]) =
    ## Set a time for temporary routes that can expire.
    ## TODO
    discard

proc getRouteInstance*[R: HttpRouter](router: var R, route: ref Route): ref Route =
    ## Return the Route object instance based on verb
    let collection = router.getCollectionByVerb(route.verb, route.routeType == DynamicRouteType)
    result = collection[route.path]

proc get*[R: HttpRouter](router: var R, path: string, callback: Callable): ref Route {.discardable.} = 
    ## Register a new route for `HttpGet` method
    result = parseRoute(path, HttpGet, callback)
    router.register(HttpGet, result)
    discard router.getRouteInstance(result)

macro get*[R: HttpRouter](router: var typedesc[R], path: static string): typed =
    ## Register a new `HttpGet` route with auto linked controller.
    ## Where `/` is linked to `getHomepage`, `/profile` to `getProfile`
    let controllerCallback = ident initControllerName(HttpGet, path)
    result = newStmtList()
    result.add quote do:
        Router.get(`path`, `controllerCallback`)

proc post*[R: HttpRouter](router: var R, path: string, callback: Callable): ref Route {.discardable.} = 
    ## Register a new route for `HttpPost` method
    result = parseRoute(path, HttpPost, callback)
    router.register(HttpPost, result)
    discard router.getRouteInstance(result)

macro post*[R: HttpRouter](router: var typedesc[R], path: static string) =
    ## Register a new `HttpPost` route with auto linked controller.
    ## Where `/profile/update` will be linked to `postProfileUpdate`
    let controllerCallback = ident initControllerName(HttpPost, path)
    result = newStmtList()
    result.add quote do:
        Router.post(`path`, `controllerCallback`)

proc put*[R: HttpRouter](router: var R, path: string, callback: Callable): ref Route {.discardable.} = 
    ## Register a new route for `HttpPut` method
    result = parseRoute(path, HttpPut, callback)
    router.register(HttpPut, result)
    discard router.getRouteInstance(result)

macro put*[R: HttpRouter](router: var typedesc[R], path: static string) =
    ## Register a new `HttpPut` route with auto linked controller.
    ## Where `/profile/insert` will be linked to `putProfileInsert`
    let controllerCallback = ident initControllerName(HttpPut, path)
    result = newStmtList()
    result.add quote do:
        Router.put(`path`, `controllerCallback`)

proc head*[R: HttpRouter](router: var R, path: string, callback: Callable): ref Route {.discardable.} = 
    ## Register a new route for `HttpHead` method
    result = parseRoute(path, HttpHead, callback)
    router.register(HttpHead, result)
    discard router.getRouteInstance(result)

macro head*[R: HttpRouter](router: var typedesc[R], path: static string) =
    ## Register a new `HttpHead` route with auto linked controller.
    let controllerCallback = ident initControllerName(HttpHead, path)
    result = newStmtList()
    result.add quote do:
        Router.head(`path`, `controllerCallback`)

proc connect*[R: HttpRouter](router: var R, path: string, callback: Callable): ref Route {.discardable.} = 
    ## Register a new route for `HttpConnect` method
    result = parseRoute(path, HttpConnect, callback)
    router.register(HttpConnect, result)
    discard router.getRouteInstance(result)

macro connect*[R: HttpRouter](router: var typedesc[R], path: static string) =
    ## Register a new `HttpConnect` route with auto linked controller.
    let controllerCallback = ident initControllerName(HttpConnect, path)
    result = newStmtList()
    result.add quote do:
        Router.connect(`path`, `controllerCallback`)

proc delete*[R: HttpRouter](router: var R, path: string, callback: Callable): ref Route {.discardable.} = 
    ## Register a new route for `HttpDelete` method
    result = parseRoute(path, HttpDelete, callback)
    router.register(HttpDelete, result)
    discard router.getRouteInstance(result)

macro delete*[R: HttpRouter](router: var typedesc[R], path: static string) =
    ## Register a new `HttpDelete` route with auto linked controller.
    let controllerCallback = ident initControllerName(HttpDelete, path)
    result = newStmtList()
    result.add quote do:
        Router.delete(`path`, `controllerCallback`)

proc patch*[R: HttpRouter](router: var R, path: string, callback: Callable): ref Route {.discardable.} = 
    ## Register a new route for `HttpPatch` method
    result = parseRoute(path, HttpPatch, callback)
    router.register(HttpPatch, result)
    discard router.getRouteInstance(result)

macro patch*[R: HttpRouter](router: var typedesc[R], path: static string) =
    ## Register a new `HttpPatch` route with auto linked controller.
    let controllerCallback = ident initControllerName(HttpPatch, path)
    result = newStmtList()
    result.add quote do:
        Router.patch(`path`, `controllerCallback`)

proc unique*[R: HttpRouter](router: var R, verb: HttpMethod, callback: Callable): ref Route {.discardable.} =
    ## Generate a unique route using provided verb and callback.
    ## Helpful for generating unique temporary URLs without
    ## dealing with database queries.
    discard

# proc assets*[R: HttpRouter](router: var R, source, public: string) =
#     ## If enabled via ``.env.yml``. Your Supranim application can
#     ## serve static assets like .css, .js, .jpg, .png and so on
#     ## Note that his procedure is recommended for serving public assets.
#     var handler = Assets.init(public, source)
#     for file in handler.discoverFiles():
#         handler.addFile(output: public & "/" & file.getPath())

proc group*[R: HttpRouter](router: var R, basePath: string, routes: varargs[GroupRouteTuple]): HttpRouter {.discardable.} =
    ## Add grouped routes under same base endpoint.
    for r in routes:
        let routePath = if r.route == "/": basePath
                        else:
                            if r.route[0] == '/': basePath & r.route
                            else: basePath  & "/" & r.route
        if not router.exists(r.verb, routePath):
            var routeObject = parseRoute(routePath, r.verb, r.callback)
            router.register(r.verb, routeObject)
            discard router.getRouteInstance(routeObject)
        else:
            raise newException(RouterException,
                "Duplicate route for \"$1\" path of $2" % [r.route, symbolName(r.verb)])
    result = router

proc setErrorPage*[R: HttpRouter](router: var R, httpCode: HttpCode, callback: proc(): string) =
    ErrorPages[httpCode.int] = callback

proc getErrorPage*(httpCode: HttpCode, default: string): string =
    let httpCodeKey = httpCode.int
    if ErrorPages.hasKey(httpCodeKey):
        result = ErrorPages[httpCode.int]()
    else: result = default

proc middleware*[R: Route](route: ref R, middlewares: varargs[Middleware]) =
    ## Attach one or more middleware handlers to current route.
    ## Note that Middlewares are parsed in the given order.
    runnableExamples:
        Router.get("/profile").middleware(middlewares.auth, middlewares.membership)
    route.hasMiddleware = true
    route.middlewares = toSeq(middlewares)

when not defined release:
    type
        LiveReload = object
            state: int64
    var liveReload = LiveReload()
    method initLiveReload*[R: HttpRouter](router: var R) {.base.} =
        ## Initialize API endpoint for reloading current screen
        let reloadCallback = proc(req: Request, res: var Response) =
            json(res, liveReload)
        Router.get("/watchout", reloadCallback)

    method refresh*[R: HttpRouter](router: var R) {.base.} =
        ## Internal method for refreshing current `HttpGet` screens.
        liveReload.state = now().toTime.toUnix
    Router.initLiveReload()