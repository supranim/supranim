# Supranim - A fast MVC web framework
# for building web apps & microservices in Nim.
#   (c) 2024 MIT License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim

import std/[httpcore, critbits, tables,
  nre, macros, macrocache, strutils, sequtils,
  enumutils]

import ../request, ../response
import ./autolink

export Request, Response, HttpCode

type
  HttpRouteType* = enum
    StaticRoute, DynamicRoute
  Callable* =
    (
      when defined supraMicroservice:
        proc(req: ptr Request, res: ptr Response): void {.nimcall, gcsafe.}
      else:
        proc(req: Request, res: var Response): void {.nimcall, gcsafe.}
    )
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
      httpTrace, httpOptions, httpErrors, httpWS: CritBitTree[HttpRoute]
    # abstractRoutes: CritBitTree[Route]

  HttpRouterError* = object of CatchableError

var Router*: HttpRouterInstance
  ## a singleton of `HttpRouterInstance`

const
  # Register default HTTP Error Handles
  # let browsers use their default screen without providing
  # a specific body
  DefaultHttpError*: Callable =
    when defined supraMicroservice:
      proc(req: ptr Request, res: ptr Response) =
        discard
    else:
      proc(req: Request, res: var Response) =
        discard

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
  middlewares: seq[Middleware] = @[],
  afterwares: seq[Afterware] = @[],
  isWebSocket = false
) =
  ## Register a new `Route`
  let path = autolinked[0]
  let routeObject =
    newHttpRoute(path, httpMethod, callback, middlewares, afterwares)
  case httpMethod
  of HttpGet:
    if isWebSocket:
      if not router.httpWS.hasKey(path):
        router.httpWS[path] = routeObject
    else:
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

const httpMethods* = ["get", "post", "put", "patch", "head",
  "delete", "trace", "options", "connect", "ws"]
  # `ws` is just an alias for `get` method used
  # internally when defining a websocket route

proc parseRouteNode*(verb, routePath: string,
  middlewares, afterwares: var NimNode,
  closureHandle: NimNode = nil
) {.compileTime.} =
  let
    httpMethod =
      if verb != "ws":
        parseEnum[HttpMethod](toUpperAscii(verb))
      else: HttpGet
    autolinked: Autolinked =
      autolinkController(routePath, httpMethod, verb == "ws")
  let controllerIdent = ident(autolinked.handleName)
  if closureHandle.isNil:
    queuedRoutes[autolinked.handleName] =
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
        newTree(nnkPrefix, ident "@", afterwares),
        nnkExprEqExpr.newTree(
          ident"isWebSocket",
          newLit(verb == "ws")
        )
      )
  else:
    let routeDescription: NimNode = 
      if closureHandle[0].kind == nnkCommentStmt:
        newLit(closureHandle[0].strVal)
      else: nil
    queuedRoutes[autolinked.handleName] =
      nnkTupleConstr.newTree(
        ident(autolinked[0]),
        newLit(autolinked[1]),
        newLit(autolinked[2]),
        ident(httpMethod.symbolName),
        routeDescription,
        newProc(
          name = ident(autolinked[0]),
          params = [
            newEmptyNode(),
            newIdentDefs(
              ident"req",
              newDotExpr(
                ident"request",
                ident"Request"
              ),
              newEmptyNode()
            ),
            newIdentDefs(
              ident"res",
              nnkVarTy.newTree(
                ident"Response"
              ),
              newEmptyNode()
            ),
          ],
          pragmas = nnkPragma.newTree(ident"nimcall"),
          body =
            nnkPragmaBlock.newTree(
              nnkPragma.newTree(
                ident"gcsafe"
              ),
              closureHandle
            )
        )
      )

proc preparePath*(path: string, prefix = ""): string {.compileTime.} =
  if prefix.len > 0:
    result = prefix
    if path == "/" and prefix == path:
      return # result
    if path[0] == '/':
      if prefix[^1] == '/':
        add result, path[1..^1]
      else:
        add result, path
    else:
      add result, "/" & path
  else:
    result = path
  if result.len > 1 and result[^1] == '/':
    return result[0..^2]

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
    var httpMethodNames: seq[NimNode]
    if x[0].kind == nnkBracketExpr:
      for verb in x[0]:
        add httpMethodNames, verb
    else:
      httpMethodNames = @[x[0]]
    for httpMethodName in httpMethodNames:
      var middlewares, afterwares = newNimNode(nnkBracket)
      if httpMethodName.eqIdent("group"):
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
                case r[0].kind
                of nnkIdent:
                  parseRouteNode(r[0].strVal,
                    preparePath(r[1].strVal, x[1].strVal),
                    middlewares, afterwares
                  )
                of nnkBracketExpr:
                  for v in r[0]:
                    parseRouteNode(v.strVal,
                      preparePath(r[1].strVal, x[1].strVal),
                      middlewares, afterwares
                    )
                else: discard # todo error
          else:
            error("Invalid route", y) 
      elif httpMethodName.strVal in httpMethods:
        let routeStmtHandle =
          if x.len == 3:
            x[2]
          else: nil
        parseRouteNode(httpMethodName.strVal,
          x[1].strVal.preparePath(), middlewares, afterwares, routeStmtHandle)
      else:
        error("Invalid HTTP method `" & httpMethodName.strVal & "`", httpMethodName)

macro searchRoute(httpMethod: static string) =
  result = newstmtList()
  let verb = ident httpMethod
  add result, quote do:
    if router.`verb`.hasKey(requestPath):
      result.route = router.`verb`[requestPath]
    else:
      for k in router.`verb`.keys:
        let someRegexMatch = requestPath.match(re(k))
        if someRegexMatch.isSome():
          result.route = router.`verb`[k]
          let pattern = someRegexMatch.get().captures()
          for key in RegexMatch(pattern).pattern.captureNameId.keys:
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

when defined supraMicroservice:
  proc call4xx*(router: var HttpRouterInstance,
      req: ptr Request, res: ptr Response) {.discardable.} =
    ## Run the `4xx` callback
    router.httpErrors["4xx"].callback(req, res)
else:
  proc call4xx*(router: var HttpRouterInstance,
      req: Request, res: var Response) {.discardable.} =
    ## Run the `4xx` callback
    router.httpErrors["4xx"].callback(req, res)

template initRouterErrorHandlers* =
  Router.errorHandler(Http404, errors.get4xx)
