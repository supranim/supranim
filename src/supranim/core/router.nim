# Supranim is a simple MVC web framework
# for building web apps & microservices in Nim.
#
# (c) 2024 MIT License | Made by Humans from OpenPeeps
# https://supranim.com | https://github.com/supranim

import std/[asyncdispatch, httpcore, critbits,
      strutils, sequtils, macros, macrocache,
      enumutils]
import ./request, ./response

from ../application import Application

type
  RouteType* = enum
    rtStatic, rtDynamic

  RouteStatus* = enum
    routeStatusNotFound
    routeStatusFound
    routeStatusBlockedByAbort
    routeStatusBlockedByRedirect

  Callable* = proc(req: Request, res: var Response, app: Application): Response {.nimcall, gcsafe.}
  Middleware* = proc(req: Request, res: var Response): HttpCode {.nimcall, gcsafe.}
  
  RoutePattern* = enum
    textPattern
    idPattern = "id"
    slugPattern = "slug"
    yearPattern = "year"
    monthPattern = "month"
    dayPattern = "day"
    uuidPattern = "uuid"
    hashPattern = "hash"

  RoutePatternTuple* = tuple[
    path: string,
    pattern: RoutePattern,
    optional: bool
  ]

  Route* = ref object
    path: string
    httpMethod: HttpMethod
    case routeType: RouteType
    of rtStatic: discard
    of rtDynamic:
      routePatterns: seq[RoutePatternTuple]
    callback*: Callable
    case hasMiddleware: bool
    of true:
      middlewares: seq[Middleware]
      aborted: bool
    else: discard

  RouterInstance = object
    httpGet, httpPost, httpPut, httpHead, httpConnect,
      httpDelete, httpPatch, httpTrace, httpOptions,
      httpErrors: CritBitTree[Route]

  RouterError* = object of CatchableError

var Router* {.threadvar.}: RouterInstance

proc getDuplicateError(httpMethod: HttpMethod, path: string): string =
  result = "Duplicate " & $(httpMethod) & " route: \"" & path & "\""

const httpMethods = ["get", "post", "put", "patch", "head",
  "delete", "trace", "options", "connect"]

proc slash(str: string): string =
  if str[0] != '/':
    return "/" & str
  result = str 

#
# Runtime API
#
proc newRouter*(): RouterInstance =
  RouterInstance()

proc newRoute(path: string, httpMethod: HttpMethod,
    callback: Callable, middlewares: seq[Middleware]): Route =
  # Create a new `Route`
  if middlewares.len == 0:
    return Route(path: path, httpMethod: httpMethod, callback: callback)
  Route(path: path, httpMethod: httpMethod, callback: callback,
    hasMiddleware: true, middlewares: middlewares)

proc newDynamicRoute(path: string, httpMethod: HttpMethod,
    callback: Callable, middlewares: seq[Middleware], patterns: seq[RoutePatternTuple]): Route =
  # Create a new `Route`
  if middlewares.len == 0:
    return Route(path: path, routeType: rtDynamic,
            httpMethod: httpMethod, callback: callback, routePatterns: patterns)
  Route(path: path, routeType: rtDynamic,
        httpMethod: httpMethod, callback: callback,
        hasMiddleware: true, middlewares: middlewares, routePatterns: patterns)

proc route*(router: var RouterInstance, path: string, httpMethod: HttpMethod,
    callback: Callable, patterns: seq[RoutePatternTuple], middlewares: seq[Middleware] = @[]) =
  ## Register a new `Route`
  let routeObject =
    if patterns.len > 0:
      newDynamicRoute(path, httpMethod, callback, middlewares, patterns)
    else:
      newRoute(path, httpMethod, callback, middlewares)
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

proc errorHandler*(router: var RouterInstance,
    code: HttpCode, callback: Callable) =
  let eobj = newRoute("4xx", HttpGet, callback, @[])
  case code
  of Http400, Http404:
    router.httpErrors["4xx"] = eobj
  else: discard

proc call4xx*(router: var RouterInstance,
    req: Request, res: var Response, app: Application): Response {.discardable.} =
  ## Run the `4xx` callback
  router.httpErrors["4xx"].callback(req, res, app)

template initRouterErrorHandlers* =
  Router.errorHandler(Http404, errors.get4xx)

proc toStr(p: RoutePattern, isOptional: bool): string =
  result = "{" & $p
  add result, if isOptional: "?}" else: "}"

proc checkExists*(router: var RouterInstance,
    path: string, httpMethod: HttpMethod): tuple[exists: bool, route: Route] =
  case httpMethod
  of HttpGet:
    if router.httpGet.hasKey(path):
      result.route = router.httpGet[path]
    else:
      let p = path[1..^1].split("/")
      for k in router.httpGet.keysWithPrefix("/" & p[0]):
        let r: Route = router.httpGet[k]
        var pKey: seq[string]
        case r.routeType
        of rtDynamic:
          for i in 0..r.routePatterns.high:
            case r.routePatterns[i].pattern
            of textPattern:
              if p[i] != r.routePatterns[i].path and 
                r.routePatterns[i].optional == false: return
              add pKey, p[i]
            of slugPattern:
              try:
                discard p[i]
                add pKey, slugPattern.toStr(r.routePatterns[i].optional)
              except Defect:
                if r.routePatterns[i].optional:
                  add pKey, toStr(r.routePatterns[i].pattern, r.routePatterns[i].optional)
                else: return
            of idPattern:
              try:
                let x = p[i]
                add pKey, idPattern.toStr(r.routePatterns[i].optional)
              except Defect:
                if r.routePatterns[i].optional:
                  add pKey, toStr(r.routePatterns[i].pattern, r.routePatterns[i].optional)
                else: return
            else: discard
          result.route = router.httpGet["/" & pKey.join("/")]
        else: discard
  of HttpPost:
    if router.httpPost.hasKey(path):
      result.route = router.httpPost[path]
  of HttpPut:
    if router.httpPut.hasKey(path):
      result.route = router.httpPut[path]
  of HttpPatch:
    if router.httpPatch.hasKey(path):
      result.route = router.httpPatch[path]
  of HttpHead:
    if router.httpPatch.hasKey(path):
      result.route = router.httpPatch[path]
  of HttpDelete:
    if router.httpDelete.hasKey(path):
      result.route = router.httpDelete[path]
  of HttpTrace:
    if router.httpTrace.hasKey(path):
      result.route = router.httpTrace[path]
  of HttpOptions:
    if router.httpOptions.hasKey(path):
      result.route = router.httpOptions[path]
  of HttpConnect:
    if router.httpConnect.hasKey(path):
      result.route = router.httpConnect[path]
  result.exists = likely(result.route != nil)

#
# Middleware API
#
proc getMiddlewares(route: Route): seq[Middleware] =
  result = route.middlewares

template next*(status: HttpCode = Http200): typed =
  return status

template fail*(status: HttpCode = Http403): typed =
  return status

template abort*(target: string = "/"): typed =
  if target.len > 0:
    res.setCode(Http302)
    res.addHeader("location", target)
    # req.redirectUri(res,target)
  return Http302

proc resolveMiddleware*(route: Route, req: Request, res: var Response): HttpCode {.gcsafe.} =
  ## Checks a `route` if has any implemented middlewares
  if route.hasMiddleware:
    result = route.middlewares[res.middlewareIndex](req, res)
    case result
    of Http200:
      inc res.middlewareIndex
      if route.middlewares.high >= res.middlewareIndex:
        return route.resolveMiddleware(req, res)
      return result
    else: return # result
  result = Http200

#
# Compile-time API 
#

var queueRouter {.compileTime.} = RouterInstance()
const queuedRoutes* = CacheTable("QueuedRoutes")
const baseMiddlewares* = CacheTable("BaseMiddlewares")

proc getNameByPath(route: string): string {.compileTime.} =
  #[
    Generates a controller name from `route` path.
    Examples:
    - GET `/`:                `getHomepage`
    - GET `/some/{slug}`:     `getSomeSlug`
    - POST `/user/picture`:   `postUserPicture` 
    - DELETE `/user/account`: `deleteUserAccount`
  ]#
  if route == "/":
    return "Homepage"
  var path =
    if route[0] == '/':
      split(route[1 .. ^1], {'/', '-'})
    else: split(route, {'/', '-'})
  for p in path.mitems:
    if p[0] != '{':
      result &= toUpperAscii(p[0])
      result &= p[1 .. ^1]
    else:
      p = p.replace("?", "")
      result &= toUpperAscii(p[1])
      result &= p[2 .. ^2]

proc genCtrl(httpMethod: HttpMethod,
    path: string): (string, NimNode) {.compileTime.} =
  ## Generate a Controller name by `path`
  if path.len > 1:
    var i = 0
    let len = path.high
    var t: RoutePatternTuple
    result[1] = newNimNode(nnkBracket)
    while i <= len:
      case path[i]
      of '/':
        if i == 0:
          discard
        else:
          t.pattern = textPattern
          add result[1], nnkTupleConstr.newTree(
            newLit(t.path),
            ident(t.pattern.symbolName),
            newLit(t.optional)
          )
          setLen(t.path, 0)
      of '{':
        inc i
        var p: string
        while i <= len:
          case path[i]
          of 'a'..'z':
            add p, path[i]
          of '?':
            t.optional = true
          of '}':
            try:
              let x = parseEnum[RoutePattern](p)
              t.path = p
              t.pattern = x
              add result[1], nnkTupleConstr.newTree(
                newLit(t.path),
                ident(t.pattern.symbolName),
                newLit(t.optional)
              )
            except ValueError:
              raise newException(RouterError, "Invalid route pattern `$1`" % [p])            
          else: break
          inc i
      of 'a'..'z', '0'..'9':
        add t.path, path[i]
      of '-', '_', '+':
        add t.path, path[i]
      else: discard
      if i == len:
        add result[1], nnkTupleConstr.newTree(
          newLit(t.path),
          ident(t.pattern.symbolName),
          newLit(t.optional)
        )
      inc i
  else:
    result[1] = newNimNode nnkBracket
  result[0] = toLowerAscii($httpMethod) & getNameByPath(path)

macro routes*(body: untyped): untyped =
  ## Register new routes
  result = newStmtList()
  add result, `body`
  # add result, quote do:
  #   proc initRouter* {.thread.} =
  #     ## Initialize a `RouterInstance` for the current thread
  #     Router = RouterInstance()

proc genCallable(callbackBody: NimNode, ctrlIdent: NimNode): NimNode {.compileTime.} =
  result =
    newProc(
      ctrlIdent,
      params = [
        ident "Response",
        newIdentDefs(ident "req", ident "Request"),
        newIdentDefs(ident "res", nnkVarTy.newTree(ident "Response") )
      ],
      body = callbackBody,
      pragmas = nnkPragma.newTree(
        ident "nimcall",
        ident "gcsafe"
      )
    )

proc checkRoute(httpMethod: HttpMethod, path: string) {.compileTime.} =
  # Checks the existence of a route at compile-time.
  case httpMethod
  of HttpGet:
    if not queueRouter.httpGet.hasKey(path):
      queueRouter.httpGet[path] = nil; return
  of HttpPost:
    if not queueRouter.httpPost.hasKey(path):
      queueRouter.httpPost[path] = nil; return
  of HttpPut:
    if not queueRouter.httpPut.hasKey(path):
      queueRouter.httpPut[path] = nil; return
  of HttpPatch:
    if not queueRouter.httpPatch.hasKey(path):
      queueRouter.httpPatch[path] = nil; return
  of HttpHead:
    if not queueRouter.httpPatch.hasKey(path):
      queueRouter.httpPatch[path] = nil; return
  of HttpDelete:
    if not queueRouter.httpDelete.hasKey(path):
      queueRouter.httpDelete[path] = nil; return
  of HttpTrace:
    if not queueRouter.httpTrace.hasKey(path):
      queueRouter.httpTrace[path] = nil; return
  of HttpOptions:
    if not queueRouter.httpOptions.hasKey(path):
      queueRouter.httpOptions[path] = nil; return
  of HttpConnect:
    if not queueRouter.httpConnect.hasKey(path):
      queueRouter.httpConnect[path] = nil; return
  raise newException(RouterError, getDuplicateError(httpMethod, path))

# todo
# a better support for macro overloading
# https://github.com/nim-lang/RFCs/issues/402
# meanwhile
const public* = newSeq[Middleware](0)

# GET
# macro get*(path: static string, middlewares: static seq[Middleware], callbackBody: untyped) =
#   ## Register a new `GET` route using `callbackBody`  
#   checkRoute(HttpGet, path)
#   var result = newStmtList()
#   let c = genCtrl(HttpGet, path)
#   let ctrl = ident(c[0])
#   queuedRoutes[c[0]] = newLit(path)
#   var patterns = nnkPrefix.newTree(ident "@", c[1])
#   result.add genCallable(callbackBody, ctrl)
#   result.add quote do:
#     Router.route(`path`, HttpGet, `ctrl`, `patterns`, `middlewares`)
#   echo result.repr

macro get*(path: static string, middlewares: seq[Middleware] = @[]) =
  ## Register a new `GET` route using auto-linking controller
  checkRoute(HttpGet, path)
  let c = genCtrl(HttpGet, path)
  let ctrl = ident(c[0])
  queuedRoutes[c[0]] = newCall(
    ident("route"),
    ident("Router"),
    newLit(path),
    ident("HttpGet"),
    ctrl,
    nnkPrefix.newTree(ident "@", c[1]),
    middlewares
  )

#
# POST
#
macro post*(path: static string, middlewares: seq[Middleware] = @[]) =
  ## Register a new `POST` route using auto-linking controller
  checkRoute(HttpPost, path)
  let c = genCtrl(HttpPost, path)
  let ctrl = ident(c[0])
  queuedRoutes[c[0]] = newCall(
    ident("route"),
    ident("Router"),
    newLit(path),
    ident("HttpPost"),
    ctrl,
    nnkPrefix.newTree(ident "@", c[1]),
    middlewares
  )

#
# PUT
#
macro put*(path: static string, middlewares: seq[Middleware] = @[]) =
  ## Register a new `PUT` route using auto-linking controller
  checkRoute(HttpPut, path)
  let c = genCtrl(HttpPut, path)
  let ctrl = ident(c[0])
  queuedRoutes[c[0]] = newCall(
    ident("route"),
    ident("Router"),
    newLit(path),
    ident("HttpPut"),
    ctrl,
    nnkPrefix.newTree(ident "@", c[1]),
    middlewares
  )

#
# PATCH
#
macro patch*(path: static string, middlewares: seq[Middleware] = @[]) =
  ## Register a new `PATCH` route using auto-linking controller
  checkRoute(HttpPatch, path)
  let c = genCtrl(HttpPatch, path)
  let ctrl = ident(c[0])
  queuedRoutes[c[0]] = newCall(
    ident("route"),
    ident("Router"),
    newLit(path),
    ident("HttpPatch"),
    ctrl,
    nnkPrefix.newTree(ident "@", c[1]),
    middlewares
  )

#
# HEAD
#
macro head*(path: static string, middlewares: seq[Middleware] = @[]) =
  ## Register a new `HEAD` route using auto-linking controller
  checkRoute(HttpHead, path)
  let c = genCtrl(HttpHead, path)
  let ctrl = ident(c[0])
  queuedRoutes[c[0]] = newCall(
    ident("route"),
    ident("Router"),
    newLit(path),
    ident("HttpHead"),
    ctrl,
    nnkPrefix.newTree(ident "@", c[1]),
    middlewares
  )

#
# DELETE
#
macro delete*(path: static string, middlewares: seq[Middleware] = @[]) =
  ## Register a new `DELETE` route using auto-linking controller
  checkRoute(HttpDelete, path)
  let c = genCtrl(HttpDelete, path)
  let ctrl = ident(c[0])
  queuedRoutes[c[0]] = newCall(
    ident("route"),
    ident("Router"),
    newLit(path),
    ident("HttpDelete"),
    ctrl,
    nnkPrefix.newTree(ident "@", c[1]),
    middlewares
  )

#
# TRACE
#
macro trace*(path: static string, middlewares: seq[Middleware] = @[]) =
  ## Register a new `TRACE` route using auto-linking controller
  checkRoute(HttpTrace, path)
  let c = genCtrl(HttpTrace, path)
  let ctrl = ident(c[0])
  queuedRoutes[c[0]] = newCall(
    ident("route"),
    ident("Router"),
    newLit(path),
    ident("HttpTrace"),
    ctrl,
    nnkPrefix.newTree(ident "@", c[1]),
    middlewares
  )

#
# OPTIONS
#
macro options*(path: static string, middlewares: seq[Middleware] = @[]) =
  ## Register a new `OPTIONS` route using auto-linking controller
  checkRoute(HttpOptions, path)
  let c = genCtrl(HttpOptions, path)
  let ctrl = ident(c[0])
  queuedRoutes[c[0]] = newCall(
    ident("route"),
    ident("Router"),
    newLit(path),
    ident("HttpOptions"),
    ctrl,
    nnkPrefix.newTree(ident "@", c[1]),
    middlewares
  )

#
# CONNECT
#
macro connect*(path: static string, middlewares: seq[Middleware] = @[]) =
  ## Register a new `CONNECT` route using auto-linking controller
  checkRoute(HttpConnect, path)
  let c = genCtrl(HttpConnect, path)
  let ctrl = ident(c[0])
  queuedRoutes[c[0]] = newCall(
    ident("route"),
    ident("Router"),
    newLit(path),
    ident("HttpConnect"),
    ctrl,
    nnkPrefix.newTree(ident "@", c[1]),
    middlewares
  )

proc registerGroupRoute(basepath: string, x: NimNode): (NimNode, NimNode) =
  let methodIdent = x[0]
  if x[0].strVal in httpMethods:
    expectKind(x[1], nnkStrLit)
    let path =
      if x[1].strVal == "/": slash(basepath)
      else: slash(basepath) & slash(x[1].strVal)
    result[0] = methodIdent
    result[1] = newLit(path)
  else:
    raise newException(RouterError, "Invalid Http handler")

macro group*(basepath: static string, x: untyped) =
  ##[
    Register a group of routes. Optionally, wrap the routes in a `pragma`
    block adding one or more middlewares
    ```
    group "/account":
      {.middleware: authenticated.}:
        get "/"         # GET /account
        get "/profile"  # GET /account/profile
        post "/profile" # POST /account/profile
    ```
  ]## 
  const allowed = {nnkCommand, nnkCall, nnkPragmaBlock}
  var middlewares = nnkPrefix.newTree(ident "@")
  result = newStmtList()
  for y in x:
    case y.kind
    of nnkCommand, nnkCall:
      let (methodNode, pathNode) = registerGroupRoute(basepath, y)
      add result, newCall(methodNode, pathNode, middlewares)
    of nnkPragmaBlock:
      # The allowed pragma block `{.middleware: [some, auth, handles].}`
      # that registers one or more middlewares for a group of routes
      expectKind(y[0][0], nnkExprColonExpr)
      expectKind(y[1], nnkStmtList)
      if y[0][0][0].eqIdent("middleware"):
        case y[0][0][1].kind
        of nnkBracket:
          add middlewares, y[0][0][1]
        of nnkIdent:
          add middlewares
        else: discard # todo error
        for r in y[1]:
          let (methodNode, pathNode) = registerGroupRoute(basepath, r)
          add result, newCall(methodNode, pathNode, middlewares)
      else:
        raise newException(RouterError, "Invalid pragma. Use `middleware` pragma to group routes")
    else: raise newException(RouterError, "Expecting one of " & $allowed)
