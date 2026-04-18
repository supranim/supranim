#
# Supranim is a high-performance web framework for building
# web applications and microservices in Nim
# 
#   (c) 2026 LGPL-v3-or-later License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#

## This module implements a simple HTTP router for the Supranim framework.
## It allows defining routes with dynamic parameters via regex patterns,
## supports route-specific middleware and afterware hooks, and provides
## compile-time macros to register routes in a declarative way
## 
## The Router is using `pkg/regex` for dynamic route matching, which allows for powerful
## parameter extraction and flexible route definitions.

import std/[httpcore, critbits, tables, macros,
        macrocache, strutils, sequtils, enumutils]

import pkg/regex

import ./request, ./response
import ./autolink

type
  HttpRouteType* = enum
    StaticRoute, DynamicRoute
  Callable* =
    (
      when defined supraMicroservice:
        proc(req: ptr Request, res: ptr Response): void {.nimcall, gcsafe.}
      elif compileOption("app", "lib"):
        proc(req: ptr Request, res: ptr Response): void {.cdecl, gcsafe.}
      else:
        proc(req: var Request, res: var Response): void {.nimcall, gcsafe.}
    )
  Middleware* = proc(req: var Request, res: var Response): HttpCode {.nimcall.}
  Afterware* = Middleware

  HttpRoute* = ref object of RootObj
    path: string
      # The `path` is the original path string used to define the route.
    regexPath: Regex2
      # The `regexPath` is used to match dynamic routes with parameters.
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
  
  HttpRouteWs* = ref object of HttpRoute


  HttpRouterInstance = ref object
    httpGet*, httpPost*, httpPut*, httpHead*,
      httpConnect*, httpDelete*, httpPatch*,
      httpTrace*, httpOptions*, httpErrors*: CritBitTree[HttpRoute]
    httpWS*: CritBitTree[HttpRouteWs]

  HttpRouterError* = object of CatchableError

var Router*: HttpRouterInstance
  ## A thread local singleton instance of `HttpRouterInstance`
  ## that is used to register routes and error handlers.
  ## 
  ## Note that this is a thread-local variable, so each thread will
  ## have its own instance of the router. This allows for better
  ## performance in multi-threaded applications, as each thread
  ## can access its own router instance without any locking mechanism

const
  # Register default HTTP Error Handles
  DefaultHttpError*: Callable =
    when defined supraMicroservice:
      proc(req: ptr Request, res: ptr Response) =
        discard
    elif compileOption("app", "lib"):
      proc(req: ptr Request, res: ptr Response) {.cdecl.} =
        discard
    else:
      proc(req: var Request, res: var Response) =
        discard

#
# Compile-time API
#
var
  queuedRoutes* {.compileTime.} = CacheTable("QueuedRoutes")
    ## A compile-time cache to store route definitions parsed from the `routes` macro.
    ## Routes are stored in this cache until they are emitted as actual route registrations
  baseMiddlewares* {.compileTime.} = CacheTable("BaseMiddlewares")
    ## A compile-time cache to store base middlewares defined at the application level.
    ## Base middlewares are middlewares that run for every incoming request before any
    ## route-specific middleware is executed.

#
# Public API
#
proc newHttpRouter*: HttpRouterInstance =
  ## Initializes a new `HttpRouterInstance`.
  HttpRouterInstance(
    httpGet: CritBitTree[HttpRoute](),
    httpPost: CritBitTree[HttpRoute](),
    httpPut: CritBitTree[HttpRoute](),
    httpPatch: CritBitTree[HttpRoute](),
    httpHead: CritBitTree[HttpRoute](),
    httpDelete: CritBitTree[HttpRoute](),
    httpTrace: CritBitTree[HttpRoute](),
    httpOptions: CritBitTree[HttpRoute](),
    httpConnect: CritBitTree[HttpRoute](),
    httpWS: CritBitTree[HttpRouteWs](),
    httpErrors: CritBitTree[HttpRoute]()
  )

proc newHttpRoute(autolinked: (string, string),
          httpMethod: HttpMethod, callback: Callable): HttpRoute =
  # Create a new `HttpRoute`
  result = HttpRoute(
    path: autolinked[1],
    httpMethod: httpMethod,
    callback: callback,
  )

proc newHttpRoute(autolinked: (string, string),
                  httpMethod: HttpMethod, callback: Callable,
                  middlewares: seq[Middleware], afterwares: seq[Afterware]): HttpRoute =
  # Create a new `HttpRoute`
  result = HttpRoute(
    path: autolinked[1],
    httpMethod: httpMethod,
    callback: callback,
    hasMiddleware: middlewares.len > 0,
    hasAfterware: afterwares.len > 0
  )
  result.regexPath = re2(autolinked[0])
  if result.hasMiddleware: result.middlewares = middlewares
  if result.hasAfterware:  result.afterwares = afterwares


proc newWsRoute(path: string, httpMethod: HttpMethod, callback: Callable,
                middlewares: seq[Middleware], afterwares: seq[Afterware]): HttpRouteWs =
  # Create a new `HttpRoute`
  result = HttpRouteWs(
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
  ## Register a new `Route` in the `HttpRouterInstance` based on the given parameters
  let path = autolinked[1] # the original path string used to define the route
  if isWebSocket:
    let routeObject = newWsRoute(path, HttpGet, callback, middlewares, afterwares)
    if not router.httpWS.hasKey(path):
      router.httpWS[path] = routeObject
  else:
    let routeObject =
      newHttpRoute(autolinked, httpMethod, callback, middlewares, afterwares)
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
      if not router.httpHead.hasKey(path):
        router.httpHead[path] = routeObject
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
                    closureHandle: NimNode = nil) {.compileTime.} =
  ## Parse a route definition and store it in the `queuedRoutes` compile-time cache.
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
        # newDotExpr(ident"App", ident"router"),
        ident"Router",
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
              nnkVarTy.newTree(
                newDotExpr(
                  ident"request",
                  ident"Request"
                )
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
  ## Prepares the route path by combining it with the given prefix and ensuring
  ## that it is in the correct format for route matching. This includes handling
  ## trailing slashes and ensuring that the path starts with a slash.
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

proc toBracketNode(nodes: seq[NimNode]): NimNode {.compileTime.} =
  # Utility function to convert a sequence of NimNodes into a 
  # ingle NimNode with kind `nnkBracket`
  result = newNimNode(nnkBracket)
  for n in nodes:
    result.add n

proc addPragmaValues(target: var seq[NimNode], value: NimNode) {.compileTime.} =
  case value.kind
  of nnkBracket, nnkTupleConstr:
    for v in value: target.add v
  of nnkPrefix:
    # supports: @[a, b, c]
    if value.len == 2 and value[0].kind == nnkIdent and value[0].eqIdent("@") and value[1].kind == nnkBracket:
      for v in value[1]: target.add v
    else:
      error("Invalid middleware/afterware value", value)
  of nnkIdent, nnkSym, nnkDotExpr, nnkCall:
    target.add value
  else:
    error("Invalid middleware/afterware value", value)

proc collectScopePragmas(pragmaNode: NimNode, middlewares,
                 afterwares: var seq[NimNode]) {.compileTime.} =
  pragmaNode.expectKind(nnkPragma)
  for p in pragmaNode:
    p.expectKind(nnkExprColonExpr)
    p[0].expectKind(nnkIdent)
    if p[0].eqIdent("middleware"):
      addPragmaValues(middlewares, p[1])
    elif p[0].eqIdent("afterware"):
      addPragmaValues(afterwares, p[1])

proc parseRoutePathExpr(pathExpr: NimNode, middlewares,
                afterwares: var seq[NimNode]): string {.compileTime.} =
  case pathExpr.kind
  of nnkStrLit:
    result = pathExpr.strVal
  of nnkPragmaExpr:
    pathExpr[0].expectKind(nnkStrLit)
    result = pathExpr[0].strVal
    collectScopePragmas(pathExpr[1], middlewares, afterwares)
  else:
    error("Invalid route path expression", pathExpr)

proc collectHttpMethodNodes(methodExpr: NimNode): seq[NimNode] {.compileTime.} =
  case methodExpr.kind
  of nnkBracketExpr, nnkTupleConstr:
    for m in methodExpr: result.add m
  else:
    result.add methodExpr

proc emitParsedRoute(
  methodNode, pathExpr: NimNode,
  prefix: string,
  inheritedMiddlewares, inheritedAfterwares: seq[NimNode],
  closureHandle: NimNode = nil
) {.compileTime.} =
  let verb = methodNode.strVal
  if verb notin httpMethods:
    error("Invalid HTTP method `" & verb & "`", methodNode)

  var mws = inheritedMiddlewares
  var aws = inheritedAfterwares
  let routePath = parseRoutePathExpr(pathExpr, mws, aws)

  var mwsNode = toBracketNode(mws)
  var awsNode = toBracketNode(aws)

  parseRouteNode(
    verb,
    preparePath(routePath, prefix),
    mwsNode,
    awsNode,
    closureHandle
  )

proc parseRoutesScope(scopeNode: NimNode, prefix: string,
              inheritedMiddlewares, inheritedAfterwares: seq[NimNode]) {.compileTime.}

proc parseCommandLike(x: NimNode, prefix: string, inheritedMiddlewares,
                    inheritedAfterwares: seq[NimNode]) {.compileTime.} =
  if x.len < 2: return

  if x[0].kind == nnkIdent and x[0].eqIdent("group"):
    x[1].expectKind(nnkStrLit)
    x[2].expectKind(nnkStmtList)
    let nextPrefix = preparePath(x[1].strVal, prefix)
    parseRoutesScope(x[2], nextPrefix, inheritedMiddlewares, inheritedAfterwares)
    return

  let routeStmtHandle = if x.len == 3: x[2] else: nil
  for m in collectHttpMethodNodes(x[0]):
    emitParsedRoute(
      m,
      x[1],
      prefix,
      inheritedMiddlewares,
      inheritedAfterwares,
      routeStmtHandle
    )

proc parseRoutesScope(scopeNode: NimNode, prefix: string, inheritedMiddlewares,
                    inheritedAfterwares: seq[NimNode]) {.compileTime.} =
  for x in scopeNode:
    case x.kind
    of nnkCommand, nnkCall:
      parseCommandLike(x, prefix, inheritedMiddlewares, inheritedAfterwares)

    of nnkInfix:
      # (get, post) -> "/path" {.middleware: [x].}
      if x.len == 3 and x[0].kind == nnkIdent and x[0].eqIdent("->") and x[1].kind == nnkTupleConstr:
        for tVerb in x[1]:
          emitParsedRoute(
            tVerb,
            x[2],
            prefix,
            inheritedMiddlewares,
            inheritedAfterwares
          )
    of nnkPragmaBlock:
      var scopedMiddlewares = inheritedMiddlewares
      var scopedAfterwares = inheritedAfterwares
      collectScopePragmas(x[0], scopedMiddlewares, scopedAfterwares)
      x[1].expectKind(nnkStmtList)
      parseRoutesScope(x[1], prefix, scopedMiddlewares, scopedAfterwares)

    else:
      discard

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
  parseRoutesScope(body, "", @[], @[])
  result = newStmtList()

macro searchRoute(httpMethod: static string) =
  result = newstmtList()
  let verb = ident httpMethod
  add result, quote do:
    if likely(router.`verb`.hasKey(requestPath)):
      result.route = router.`verb`[requestPath]
    else:
      for k, r in router.`verb`:
        var m: RegexMatch2
        if find(requestPath, r.regexPath, m):
          result.route = r
          for name in m.groupNames():
            let g = m.group(name)
            if g != reNonCapture:
              result.params[name] = requestPath[g]
          break

macro searchRouteWs*() =
  ## Search for a WebSocket route
  result = newstmtList()
  add result, quote do:
    if router.httpWS.hasKey(requestPath):
      result.route = router.httpWS[requestPath]
    else:
      for k, r in router.httpWS:
        var m: RegexMatch2
        if find(requestPath, r.regexPath, m):
          result.route = r
          for name in m.groupNames():
            let g = m.group(name)
            if g != reNonCapture:
              result.params[name] = requestPath[g]
          break

type
  RouteCheckResult* = tuple[exists: bool, route: HttpRoute, params: Table[string, string]]

proc checkExists*(router: var HttpRouterInstance,
            requestPath: string, httpMethod: HttpMethod): RouteCheckResult =
  ## Check if a route exists for the given request path and HTTP method
  case httpMethod
    of HttpGet:     searchRoute("httpGet")
    of HttpPost:    searchRoute("httpPost")
    of HttpPut:     searchRoute("httpPut")
    of HttpPatch:   searchRoute("httpPatch")
    of HttpHead:    searchRoute("httpHead")
    of HttpDelete:  searchRoute("httpDelete")
    of HttpTrace:   searchRoute("httpTrace")
    of HttpOptions: searchRoute("httpOptions")
    of HttpConnect: searchRoute("httpConnect")
  result.exists =
    likely(result.route != nil)

proc checkWsExists*(router: var HttpRouterInstance, requestPath: string): RouteCheckResult =
  ## Check if a WebSocket route exists for the given request path
  searchRouteWs()
  result.exists = likely(result.route != nil)

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
  ## Register an error handler for a specific HTTP status code
  let httpRoute = newHttpRoute(("", "4xx"), HttpGet, callback)
  case code
  of Http400, Http404:
    router.httpErrors["4xx"] = httpRoute
  else: discard

when defined supraMicroservice:
  proc call4xx*(router: var HttpRouterInstance,
                req: ptr Request, res: ptr Response) {.discardable.} =
    ## Run the `4xx` callback
    router.httpErrors["4xx"].callback(req, res)
elif compileOption("app", "lib"):
  proc call4xx*(router: var HttpRouterInstance,
                req: ptr Request, res: ptr Response) {.cdecl, discardable.} =
    ## Run the `4xx` callback
    router.httpErrors["4xx"].callback(req, res)
else:
  proc call4xx*(router: var HttpRouterInstance,
                req: var Request, res: var Response) {.discardable.} =
    ## Run the `4xx` callback
    router.httpErrors["4xx"].callback(req, res)

template initRouterErrorHandlers* =
  ## Initialize default error handlers for the router. This is called during
  ## application startup to ensure that there is always a default error handler for HTTP 4xx errors
  Router.errorHandler(Http404, errors.get4xx)
