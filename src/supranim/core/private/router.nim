# Supranim is a simple MVC-style web framework for building
# fast web applications, REST API microservices and other cool things.
#
# (c) 2021 Supranim is released under MIT License
#          George Lemon | Made by Humans from OpenPeep
#          https://supranim.com   |    https://github.com/supranim

import std/[tables, macros, with, uri, strutils, times, options, sequtils, enumutils]
from ./server import HttpMethod, Request, Response, RoutePattern,
                    RoutePatternTuple, RoutePatternRequest, HttpCode,
                    HttpResponse, shouldRedirect

when not defined release:
  # Register a dev-only route for hot code reloading support.
  # See proc `initLiveReload` at the bottom of this file
  import jsony
  import std/[times, json]
  from ./server import json

export HttpMethod, Response, Request, HttpCode

type

  Callable* = proc(req: Request, res: var Response): HttpResponse {.nimcall.}
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

  Route* = ref object
    path: string
    verb: HttpMethod
    case routeType: RouteType 
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
    route: Route
  ]

  VerbCollection* = TableRef[string, Route]
    ## ``VerbCollection``, is a table that contains Route Objects stored by their path
    ## Note that, each ``HttpMethod`` has its own collection.
    ## Also, based on their ``routeType``, route objects can be
    ## stored either in ``httpGet`` or ``httpGetDynam``
  GroupRouteTuple* = tuple[verb: HttpMethod, route: string, callback: Callable]

  ErrorPagesTable = Table[int, proc(): string]
  HttpRouter = object
    ## Router Handler that holds all VerbCollection tables Table[string, Route]
    httpGet, httpPost, httpPut, httpHead, httpConnect,
      httpDelete, httpPatch, httpTrace, httpOptions: VerbCollection
      ## VerbCollection reserved for all static routes (routes without specific patterns)
    httpGetDynam, httpPostDynam, httpPutDynam, httpHeadDynam, httpConnectDynam,
      httpDeleteDynam, httpPatchDynam, httpTraceDynam, httpOptionsDynam: VerbCollection
      ## VerbCollection reserved for dynamic routes (routes containing patterns)

  RouterException* = object of CatchableError
    ## Catchable Router Exception

proc setField[T: VerbCollection](k: string, val: var T) =
  val = newTable[string, Route]()

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

proc isDynamic*(route: Route): bool =
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

proc getCollectionByVerb(router: var HttpRouter, verb: HttpMethod, hasParams = false): VerbCollection  =
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

proc exists*(router: var HttpRouter, verb: HttpMethod, path: string): bool =
  ## Determine if requested route exists for given `HttpMethod`
  let collection = router.getCollectionByVerb(verb)
  result = collection.hasKey(path)

proc register(router: var HttpRouter, verb: HttpMethod, route: Route) =
  ## Register a new route by given Verb and Route object
  if not Router.exists(verb, route.path): # prevent overwriting an existing route
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

proc tokenize(path: string): tuple[routeType: RouteType, patterns: seq[RoutePatternTuple]] =
  proc getPattern(str: string, isOptional, isDynamic = false): RoutePatternTuple =
    var pattern: RoutePattern
    if str == "id":
      pattern = Id
    else:
      for chr in toSeq(str):
        if isDigit(chr):
          if pattern == Slug: discard
          else: pattern = Id
        elif isAlphanumeric(chr):  pattern = Slug
        elif isAlphaAscii(chr):    pattern = Alpha
    (pattern, str, isOptional, isDynamic)

  var
    i = 0
    tks = path.toSeq()
    tksLen = tks.len - 1
    patt: string
    isDynamic: bool
  while i <= tksLen:
    case tks[i]:
    of {'0' .. '9'}:
      setLen(patt, 0)
      while tks[i] notin {'a'..'z', '{', '/'}:
        add patt, tks[i]
        inc i
        if i> tksLen: break
      result.patterns.add getPattern(patt)
    of {'a' .. 'z'}:
      setLen(patt, 0)
      while tks[i] notin {'{', '/'}:
        add patt, tks[i]
        inc i
        if i > tksLen: break
      result.patterns.add getPattern(patt)
    of '{':
      inc i
      setLen(patt, 0)
      var isOptional =
        if tks[i] == '?':
          inc i
          true
        else: false
      while tks[i] != '}':
        if tks[i] notin {'a'..'z'}:
          raise newException(RouterException, "Invalid route pattern")
        add patt, tks[i]
        inc i
      inc i # }
      result.patterns.add getPattern(patt, isOptional, true)
      isDynamic = true
    of '/':
      inc i
    else: discard
  if isDynamic:
    result.routeType = DynamicRouteType

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
  let routePattern = tokenize(path)
  result = Route()
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
  var path =
    if route[0] == '/':
      split(route[1 .. ^1], {'/', '-'})
    else: split(route, {'/', '-'})
  for p in path:
    if p[0] != '{':
      result &= toUpperAscii(p[0])
      result &= p[1 .. ^1]
    else:
      result &= toUpperAscii(p[1])
      result &= p[2 .. ^2]

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

template runMiddleware(result: RuntimeRouteStatus) =
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

proc tryMatchRoute(reqRoutePattern: seq[RoutePatternRequest], route: Route): bool =
  var i = 0
  while reqRoutePattern.len > i:
    if reqRoutePattern[i].pattern == route.patterns[i].pattern:
      if not route.patterns[i].dynamic:
        if reqRoutePattern[i].str != route.patterns[i].str: 
          return
      else: discard # todo collect dynamic from route
    else: return
    inc i
  result = true

proc runtimeExists*(router: var HttpRouter, verb: HttpMethod, path: string,
                    req: Request, res: var Response): RuntimeRouteStatus =
  let staticRoutes = router.getCollectionByVerb(verb)
  var requestUri: Uri = parseUri(path)
  var requestPath = requestUri.path
  try:
    result.route = staticRoutes[requestPath]
    result.runMiddleware()
  except ValueError:
    let dynamicRoutes = router.getCollectionByVerb(verb, true)
    var
      reqRoutePattern = getPatternsByStr(requestPath)
      reqPatternKeys: seq[int]
      matchRoutePattern: bool
    for key, route in dynamicRoutes:
      let len = route.patterns.len
      let reqLen = reqRoutePattern.len
      # TODO handle optional patterns
      if len != reqLen:
        continue # skip to next route
      else:
        if tryMatchRoute(reqRoutePattern, route):
          result.route = route
          result.key = route.path
          result.runMiddleware()
          for reqPatternKey in reqPatternKeys:
            # delete all non dynamic pattern by index key.
            # in this way `reqPattern` will contain only dynamic patterns that
            # need to be exposed in controlled-based procedure to retrieve values.
            reqRoutePattern.del(reqPatternKey)
          result.params = reqRoutePattern
          result.status = Found
          return
    result.status = NotFound

proc runCallable*(route: Route, req: var Request, res: var Response): HttpResponse =
  ## Run callable from route controller
  route.callback(req, res)

proc getRouteInstance*[R: HttpRouter](router: var R, route: Route): Route =
  ## Return the Route object instance based on verb
  let collection = router.getCollectionByVerb(route.verb, route.routeType == DynamicRouteType)
  result = collection[route.path]

proc get*[R: HttpRouter](router: var R, path: string, callback: Callable): Route {.discardable.} = 
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

proc post*[R: HttpRouter](router: var R, path: string, callback: Callable): Route {.discardable.} = 
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

proc put*[R: HttpRouter](router: var R, path: string, callback: Callable): Route {.discardable.} = 
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

proc head*[R: HttpRouter](router: var R, path: string, callback: Callable): Route {.discardable.} = 
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

proc connect*[R: HttpRouter](router: var R, path: string, callback: Callable): Route {.discardable.} = 
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

proc delete*[R: HttpRouter](router: var R, path: string, callback: Callable): Route {.discardable.} = 
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

proc patch*[R: HttpRouter](router: var R, path: string, callback: Callable): Route {.discardable.} = 
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

proc middleware*(route: Route, middlewares: varargs[Middleware]): Route {.discardable.} =
  ## Attach one or more middleware to given `Route`
  runnableExamples:
    Router.get("/profile").middleware(middlewares.auth, middlewares.membership)
  assert route.hasMiddleware == false # cannot be called more than once per `Route`
  route.hasMiddleware = true
  route.middlewares = toSeq(middlewares)
  result = route

when not defined release:
  type
    LiveReload = object
      state: int64
  var liveReload = LiveReload()
  proc initLiveReload*[R: HttpRouter](router: var R) =
    ## Initialize API endpoint for reloading current screen
    let reloadCallback = proc(req: Request, res: var Response): HttpResponse =
      json(res, liveReload)
    Router.get("/dev/live", reloadCallback)

  proc refresh*[R: HttpRouter](router: var R) =
    ## Internal proc for refreshing current `HttpGet` screens.
    liveReload.state = now().toTime.toUnix
  Router.initLiveReload()