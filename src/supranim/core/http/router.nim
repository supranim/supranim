import std/[httpcore, critbits, tables,
  nre, macros, macrocache, strutils, sequtils,
  enumutils]

import ../request, ../response
import ./autolink

type
  HttpRouteType* = enum
    StaticRoute, DynamicRoute

  Callable* = proc(req: Request, res: var Response): Response {.nimcall, gcsafe.}
  Middleware* = proc(req: Request, res: var Response): HttpCode {.nimcall.}
  Afterware* = Middleware

  HttpRoute* = ref object
    path: string
    httpMethod: HttpMethod
    callback*: Callable
    case httpRouteType: HttpRouteType
      of DynamicRoute:
        routePatterns: RoutePatternsTable
      else: discard
    case hasMiddleware: bool
      of true:
        middlewares: seq[Middleware]
      else: discard
    case hasAfterware: bool
      of true:
        afterwares: seq[Afterware]
      else: discard

  HttpRouterInstance = object
    httpGet, httpPost, httpPut, httpHead,
      httpConnect, httpDelete, httpPatch,
      httpTrace, httpOptions, httpErrors: CritBitTree[HttpRoute]
    # abstractRoutes: CritBitTree[Route]

  HttpRouterError* = object of CatchableError

var Router*: HttpRouterInstance
  ## a singleton of `HttpRouterInstance`

#
# Compile-time API
#
var queueRouter {.compileTime.} = HttpRouterInstance()
const
  queuedRoutes* = CacheTable("QueuedRoutes")
  baseMiddlewares* = CacheTable("BaseMiddlewares")

#
# Public API
#
proc newHttpRouter*: HttpRouterInstance = HttpRouterInstance()

proc newHttpRoute(path: string,
  httpMethod: HttpMethod, callback: Callable
): HttpRoute =
  # Create a new `HttpRoute`
  result = HttpRoute(
    path: path,
    httpMethod: httpMethod,
    callback: callback,
  )

proc newHttpRoute(path: string,
    httpMethod: HttpMethod, callback: Callable,
    middlewares: seq[Middleware],
    afterwares: seq[Afterware]
): HttpRoute =
  # Create a new `HttpRoute`
  result = HttpRoute(
    path: path,
    httpMethod: httpMethod,
    callback: callback,
    hasMiddleware: middlewares.len > 0,
    hasAfterware: afterwares.len > 0
  )
  if result.hasMiddleware: result.middlewares = middlewares
  if result.hasAfterware:  result.afterwares = afterwares

proc registerRoute*(router: var HttpRouterInstance,
  autolinked: sink (string, string),
  httpMethod: HttpMethod,
  callback: Callable,
  middlewares: seq[Middleware],
  afterwares: seq[Afterware]
) =
  ## Register a new `Route`
  let path = autolinked[0]
  let routeObject =
    newHttpRoute(path, httpMethod, callback, middlewares, afterwares)
  case httpMethod
  of HttpGet:
    if not router.httpGet.hasKey(path):
      router.httpGet[path] = routeObject
  of HttpPost:
    if not router.httpPost.hasKey(path):
      router.httpPost[path] = routeObject
  of HttpPut:
    if not router.httpPut.hasKey(path):
      router.httpPut[path] = routeObject
  of HttpPatch:
    if not router.httpPatch.hasKey(path):
      router.httpPatch[path] = routeObject
  of HttpHead:
    if not router.httpPatch.hasKey(path):
      router.httpPatch[path] = routeObject
  of HttpDelete:
    if not router.httpDelete.hasKey(path):
      router.httpDelete[path] = routeObject
  of HttpTrace:
    if not router.httpTrace.hasKey(path):
      router.httpTrace[path] = routeObject
  of HttpOptions:
    if not router.httpOptions.hasKey(path):
      router.httpOptions[path] = routeObject
  of HttpConnect:
    if not router.httpConnect.hasKey(path):
      router.httpConnect[path] = routeObject

const httpMethods = ["get", "post", "put", "patch", "head",
  "delete", "trace", "options", "connect"]
  
proc parseRouteNode(verb, routePath: string,
  middlewares, afterwares: var NimNode
) {.compileTime.} =
  let
    httpMethod = parseEnum[HttpMethod](toUpperAscii(verb))
    autolinked = autolinkController(routePath, httpMethod)
  let controllerIdent = ident(autolinked.handleName)
  queuedRoutes[autolinked.path] =
    newCall(
      ident"registerRoute",
      newDotExpr(ident"app", ident"router"),
      nnkTupleConstr.newTree(
        newLit(autolinked[1]),
        newLit(autolinked[2]),
      ),
      ident(httpMethod.symbolName),
      controllerIdent,
      newTree(nnkPrefix, ident "@", middlewares),
      newTree(nnkPrefix, ident "@", afterwares)
    )

proc preparePath(path: string, prefix = ""): string {.compileTime.} =
  if prefix.len > 0:
    add result, prefix
    if path == "/" and prefix == path:
      return # result
    if path[0] == '/' and prefix == "/":
      add result, path[1..^1]
  elif path.len > 1:
    if path[^1] == '/':
      return path[1..^2]
    result = path

macro routes*(body: untyped): untyped =
  ##[
    Register routes at compile-time under the `routes` macro.
    Routes are auto-linked to their controller based 
    on given path. For example a route like `get "/electronics/{category:id}"`
    will try to link to `getElectronicsCategory` handle
    ```nim    
routes:
  get "/auth/login"
  post "/auth/login"

  get "/auth/register"
  post "/auth/register" {.afterware: @[newCustomerEvent].}

  # attach one or more middlwares to the route.
  # note that middlewares are called in the given order
  get "/account" {.middleware: @[auth, member].}
    ```
    This macro supports groups of routes (under the same prefix).
    Also, grouped routes can be middleware-protected:
    ```nim
group "/account":
  {.middleware: authenticated.}:
    get "/"         # GET /account
    get "/profile"  # GET /account/profile
    post "/profile" # POST /account/profile
    ```
  ]## 
  for x in body:
    x.expectKind(nnkCommand)
    let httpMethodName = x[0]
    var middlewares, afterwares = newNimNode(nnkBracket)
    if httpMethodName.strVal in httpMethods:
      # todo parse middlwares/afterwares
      parseRouteNode(httpMethodName.strVal, x[1].strVal.preparePath(),
        middlewares, afterwares)
    elif httpMethodName.eqIdent("group"):
      x[1].expectKind(nnkStrLit)
      x[2].expectKind(nnkStmtList)
      for y in x[2]:
        case y.kind
        of nnkCommand, nnkCall:
          # parse prefixed routes
          parseRouteNode(y[0].strVal,
            preparePath(y[1].strVal, x[1].strVal),
            middlewares, afterwares
          )
        of nnkPragmaBlock:
          # The allowed pragma block `{.middleware: [some, auth, handles].}`
          # that registers one or more middlewares for a group of routes
          expectKind(y[0][0], nnkExprColonExpr)
          expectKind(y[1], nnkStmtList)
          if y[0][0][0].eqIdent("middleware"):
            case y[0][0][1].kind
            of nnkBracket:
              for m in y[0][0][1]:
                add middlewares, m
            of nnkIdent:
              add middlewares
            else: discard # todo error
            for r in y[1]:
              parseRouteNode(r[0].strVal,
                preparePath(r[1].strVal, x[1].strVal),
                middlewares, afterwares
              )
        else:
          error("Invalid route", y) 
    else:
      error("Use a valid http method or `group` for grouping routes under the same prefix path", x[0])

macro searchRoute(httpMethod: static string) =
  result = newstmtList()
  let verb = ident httpMethod
  add result, quote do:
    if router.`verb`.hasKey(requestPath):
      # static routes are easy to find!
      result.route = router.`verb`[requestPath]
    else:
      for k in router.`verb`.keys:
        let someRegexMatch = requestPath.match(re(k))
        if someRegexMatch.isSome():
          result.route = router.`verb`[k]
          let pattern = someRegexMatch.get().captures()
          for key in RegexMatch(pattern).pattern.captureNameId.keys:
            # if key in pattern: # we know it's a match
            result.params[key] = pattern[key]
          break

proc checkExists*(
  router: var HttpRouterInstance,
  requestPath: string,
  httpMethod: HttpMethod
): tuple[
    exists: bool,
    route: HttpRoute,
    params: owned Table[string, string]
  ] =
  case httpMethod
    of HttpGet:     searchRoute("httpGet")
    of HttpPost:    searchRoute("httpPost")
    of HttpPut:     searchRoute("httpPut")
    of HttpPatch:   searchRoute("httpPatch")
    of HttpHead:    searchRoute("httpHead")
    of HttpDelete:  searchRoute("httpDelete")
    of HttpTrace:   searchRoute("httpTrace")
    of HttpOptions: searchRoute("httpTrace")
    of HttpConnect: searchRoute("httpConnect")
  result.exists =
    likely(result.route != nil)

#
# Middleware API
#
proc getMiddlewares(route: HttpRoute): seq[Middleware] =
  result = route.middlewares

proc resolveMiddleware*(route: HttpRoute,
    req: var Request, res: var Response): HttpCode =
  ## Checks a `route` if has any implemented middlewares
  if route.hasMiddleware:
    result = route.middlewares[res.middlewareIndex](req, res)
    case result
    of Http204:
      inc res.middlewareIndex
      if route.middlewares.high >= res.middlewareIndex:
        return route.resolveMiddleware(req, res)
      return result
    else: return # result
  result = Http204

#
# Afterware API
#
proc resolveAfterware*(route: HttpRoute,
  req: var Request, res: var Response): HttpCode =
  ## Resolve an `Afterware` handle after a request
  ## has been made
  if route.hasAfterware:
    result = route.afterwares[res.afterwareIndex](req, res)
    case result
    of Http204:
      inc res.afterwareIndex
      if route.afterwares.high >= res.afterwareIndex:
        return route.resolveAfterware(req, res)
      return result
    else: return # result
  result = Http202


#
# Error Handles
#
proc errorHandler*(router: var HttpRouterInstance,
    code: HttpCode, callback: Callable) =
  let httpRoute = newHttpRoute("4xx", HttpGet, callback)
  case code
  of Http400, Http404:
    router.httpErrors["4xx"] = httpRoute
  else: discard

proc call4xx*(router: var HttpRouterInstance,
    req: Request, res: var Response): Response {.discardable.} =
  ## Run the `4xx` callback
  router.httpErrors["4xx"].callback(req, res)

template initRouterErrorHandlers* =
  Router.errorHandler(Http404, errors.get4xx)
