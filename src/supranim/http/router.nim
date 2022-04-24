# Supranim is a simple Hyper Server and Web Framework developed
# for building safe & fast in-house applications.
#
# (c) 2021 Supranim is released under MIT License
#          by George Lemon <georgelemon@protonmail.com>
#          
#          Website https://supranim.com
#          Github Repository: https://github.com/supranim

import std/[tables, macros]

from std/times import DateTime
from std/options import Option
from std/enumutils import symbolName
from std/strutils import `%`, split, isAlphaNumeric, isAlphaAscii, isDigit, startsWith
from std/sequtils import toSeq

from ../server import HttpMethod, Request, Response, RoutePattern, RoutePatternTuple, RoutePatternRequest

export HttpMethod

type
    Callable* = proc(req: Request, res: Response) {.nimcall.}
        ## Callable procedure for route callbacks

    MiddlewareFunction = proc(req: Request)
        ## Callable Middleware Function

    Middleware* = object
        ## Middleware object
        name*: string
            ## Middleware identifier
        callable*: proc(req: Request): void {.gcsafe.}
            ## Callable Middleware procedure 

    RouteType = enum
        ## Define available route types, it can be either static,
        ## or dynamic (when using Route patterns)
        StaticRouteType, DynamicRouteType

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
            ## A callable callback of type
            ## Callable = proc (req: Request, res: Response){.nimcall.}
        case hasMiddleware: bool
            ## Determine if current Route object has one or
            ## more middleware attached to it.
            of true:
                middleware: seq[tuple[id: string, callable: Middleware]]
                    ## A sequence of Middlewares. Note that middlewares
                    ## are always checked in the same order that have been provided.
            else: discard
        case isTemporary: bool
            ## Determine if current Route object is set as a temporary route.
            ## In this case, the route access can expire in a certain amount of time.
            of true:
                expiration: Option[DateTime]
                    ## The expiration DateTime
            else: discard

    RuntimeRoutePattern* = tuple[status: bool, key: string, params: seq[RoutePatternRequest], route: Route]

    VerbCollection* = Table[string, Route]
        ## ``VerbCollection``, is a table that contains Route Objects stored by their path
        ## Note that, each ``HttpMethod`` has its own collection.
        ## Also, based on their ``routeType``, route objects can be
        ## stored either in ``httpGet`` or ``httpGetDynam``
    GroupRouteTuple* = tuple[verb: HttpMethod, route: string, callback: Callable]

    RouterHandler = object
        ## Router Handler that holds all VerbCollection tables Table[string, Route]
        httpGet, httpPost, httpPut, httpHead, httpConnect: VerbCollection
        httpDelete, httpPatch, httpTrace, httpOptions: VerbCollection
            ## VerbCollection reserved for all static routes (routes without specific patterns)

        httpGetDynam, httpPostDynam, httpPutDynam, httpHeadDynam, httpConnectDynam: VerbCollection
        httpDeleteDynam, httpPatchDynam, httpTraceDynam, httpOptionsDynam: VerbCollection
            ## VerbCollection reserved for dynamic routes (routes containing patterns)

    RouterException* = object of CatchableError
        ## Catchable Router Exception

var Router* = RouterHandler()   # Singleton of RouterHandler

proc isDynamic*[R: Route](route: R): bool =
    ## Determine if current routeType of route object instance is type of ``DynamicRouteType``
    result = route.routeType == DynamicRouteType

proc register[R: RouterHandler](router: var R, verb: HttpMethod, route: Route) =
    ## Register a new route by given Verb and Route object
    case verb:
        of HttpGet:
            if isDynamic(route):   router.httpGetDynam[route.path] = route
            else:                  router.httpGet[route.path] = route
        of HttpPost:
            if isDynamic(route):    router.httpPostDynam[route.path] = route
            else:                   router.httpPost[route.path] = route
        of HttpPut:      router.httpPut[route.path] = route
        of HttpHead:     router.httpHead[route.path] = route
        of HttpConnect:  router.httpConnect[route.path] = route
        of HttpDelete:   router.httpDelete[route.path] = route
        of HttpPatch:    router.httpPatch[route.path] = route
        of HttpTrace:    router.httpTrace[route.path] = route
        of HttpOptions:  router.httpOptions[route.path] = route

macro getCollection(router: object, field: string, hasParams: bool): untyped =
    ## Retrieve a Collection of routes from ``RouterHandler``
    nnkStmtList.newTree(
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

proc getCollectionByVerb*[R: RouterHandler](router: var R, verb: HttpMethod, hasParams = false): VerbCollection  =
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

proc getPattern(curr, str: string, opt, dynamic = false): RoutePatternTuple =
    ## Create a RoutePattern based on given string pattern containing:
    ## ``tuple[pattern: Pattern, str: string, optional: bool]``
    ## where ``pattern`` field must be an item from Pattern enum,
    ## ``str`` field is automatically filled if route is statically declared,
    ## and ``opt`` if current route should be considered optional.
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
                if isDigit(currChar):           pattern = Id
                elif isAlphanumeric(currChar):  pattern = Slug
                elif isAlphaAscii(currChar):    pattern = Alpha
            # raise newException(RouterException, "Invalid RoutePattern declaration for \"$1\"" % [curr])
    result = (pattern: pattern, str: str, optional: opt, dynamic: dynamic)

proc getPatternsByStr(path: string): seq[RoutePatternRequest] =
    ## Create a sequence of RoutePattern of current path request.
    let pathSeq: seq[string] = path.split("/")
    for pathStr in pathSeq:
        if pathStr.len == 0: continue
        var pattern: RoutePattern
        for pathSeqChar in pathStr.toSeq:
            if isDigit(pathSeqChar):
                if pattern == Slug: pattern = Slug
                else: pattern = Id
            elif isAlphanumeric(pathSeqChar):
                pattern = Slug
            elif isAlphaAscii(pathSeqChar):
                pattern = Alpha
        result.add((pattern: pattern, str: pathStr))
        pattern = None

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

proc parseRoute(path: string, verb: HttpMethod, callback: Callable): Route =
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
    result = Route(
        path: path,
        verb: verb,
        routeType: StaticRouteType,
        callback: callback
    )
    let routePattern = parseRoutePath(path)
    if routePattern.routeType == DynamicRouteType:
        # determine if routeType is DynamicRouteType, which
        # in this case route object should contain dymamic patterns.
        result.routeType = DynamicRouteType
        result.patterns = routePattern.patterns
        for pattern in result.patterns:
            # find dynamic patterns and store in separate field
            # as params for later use on request in controller-based procedures
            if pattern.dynamic:
                result.params.add(pattern)

proc exists[R: RouterHandler](router: var R, verb: HttpMethod, path: string): bool =
    ## Determine if route exists for given `key/path` based on verb.
    ## First it looks for static routes, if not found, will check the pattern-based routes.
    let collection = router.getCollectionByVerb(verb)
    result = collection.hasKey(path)

proc existsRuntime*[R: RouterHandler](router: var R, verb: HttpMethod, path: string): RuntimeRoutePattern =
    ## Determine if route exists for given ``key/path`` based on current HttpMethod verb.
    ## This is a procedure called only on runtime on each request.
    let collection = router.getCollectionByVerb(verb)
    result.status = collection.hasKey(path)
    result.key = path
    if result.status == false:
        let dynamicCollection = router.getCollectionByVerb(verb, true)
        var reqPattern = getPatternsByStr(path)
        var matchRoutePattern: bool
        var reqPatternKeys: seq[int]
        for key, route in dynamicCollection.pairs():
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
                result.status = true
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
        result.route = collection[path]

proc isTemporary*[R: RouterHandler](router: R, verb: HttpMethod, path: string): bool =
    ## Determine if specified route has expiration time
    let collection = router.getCollectionByVerb(verb)
    result = collection[path].isTemporary

proc runCallable*[R: Route](route: R, req: var Request, res: var Response) =
    ## Run callable from route controller
    route.callback(req, res)

proc middleware*[R: Route](route: var R, middlewares: seq[tuple[id: string, callable: proc(req: Request): void {.gcsafe, nimcall.}]]) =
    ## Set one or more middleware handlers to current Route
    route.hasMiddleware = true
    route.middleware = middlewares

proc expire*[R: Route](route: var R, expiration: Option[DateTime]) =
    ## Set a time for temporary routes that can expire.
    ## TODO
    discard

proc getRouteInstance*[R: RouterHandler](router: var R, route: var Route): Route =
    ## Return the Route object instance based on verb
    let collection = router.getCollectionByVerb(route.verb, route.routeType == DynamicRouteType)
    result = collection[route.path]

proc get*[R: RouterHandler](router: var R, path: string, callback: Callable): Route {.discardable.} = 
    ## Register a new route for `HttpGet` method
    var route: Route = parseRoute(path, HttpGet, callback)
    router.register(HttpGet, route)
    result = router.getRouteInstance(route)

proc post*[R: RouterHandler](router: var R, path: string, callback: Callable): Route {.discardable.} = 
    ## Register a new route for `HttpPost` method
    var route: Route = parseRoute(path, HttpPost, callback)
    router.register(HttpPost, route)
    result = router.getRouteInstance(route)

proc put*[R: RouterHandler](router: var R, path: string, callback: Callable): Route {.discardable.} = 
    ## Register a new route for `HttpPut` method
    var route: Route = parseRoute(path, HttpPut, callback)
    router.register(HttpPut, route)
    result = router.getRouteInstance(route)

proc head*[R: RouterHandler](router: var R, path: string, callback: Callable): Route {.discardable.} = 
    ## Register a new route for `HttpHead` method
    var route: Route = parseRoute(path, HttpHead, callback)
    router.register(HttpHead, route)
    result = router.getRouteInstance(route)

proc connect*[R: RouterHandler](router: var R, path: string, callback: Callable): Route {.discardable.} = 
    ## Register a new route for `HttpConnect` method
    var route: Route = parseRoute(path, HttpConnect, callback)
    router.register(HttpConnect, route)
    result = router.getRouteInstance(route)

proc delete*[R: RouterHandler](router: var R, path: string, callback: Callable): Route {.discardable.} = 
    ## Register a new route for `HttpDelete` method
    var route: Route = parseRoute(path, HttpDelete, callback)
    router.register(HttpDelete, route)
    result = router.getRouteInstance(route)

proc patch*[R: RouterHandler](router: var R, path: string, callback: Callable): Route {.discardable.} = 
    ## Register a new route for `HttpPatch` method
    var route: Route = parseRoute(path, HttpPatch, callback)
    router.register(HttpPatch, route)
    result = router.getRouteInstance(route)

proc unique*[R: RouterHandler](router: var R, verb: HttpMethod, callback: Callable): Route {.discardable.} =
    ## Generate unique route for specified verb
    discard

# proc assets*[R: RouterHandler](router: var R, source, public: string) =
#     ## If enabled via ``.env.yml``. Your Supranim application can
#     ## serve static assets like .css, .js, .jpg, .png and so on
#     ## Note that his procedure is recommended for serving public assets.
#     var handler = Assets.init(public, source)
#     for file in handler.discoverFiles():
#         handler.addFile(output: public & "/" & file.getPath())

proc group*[R: RouterHandler](router: var R, basePath: string, routes: varargs[GroupRouteTuple]): RouterHandler {.discardable.} =
    ## Add grouped routes under same base endpoint.
    for r in routes:
        let routePath = if r.route == "/":
                            basePath
                        else:
                            if r.route[0] == '/': basePath & r.route
                            else: basePath  & "/" & r.route
        if not router.exists(r.verb, routePath):
            var routeObject: Route = parseRoute(routePath, r.verb, r.callback)
            router.register(r.verb, routeObject)
        else:
            raise newException(RouterException,
                "Duplicate route for \"$1\" path of $2" % [r.route, symbolName(r.verb)])
    result = router
