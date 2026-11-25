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
## The Router is using `pkg/openparser/regex` for dynamic route matching, which allows for powerful
## parameter extraction and flexible route definitions.
##
## Dynamic route patterns are JIT-compiled to native code at registration:
## the generated code is immutable and shared across workers, while every
## worker thread executes it on a private JIT context — so route lookups
## stay safe under the router's read lock with no shared mutable VM state.

import std/[critbits, tables, macros, options,
        macrocache, strutils, enumutils]

import pkg/openparser/regex
from pkg/openparser/regex/jit/compiler import CompiledJit, JitCtx,
  compileRegex, newJitCtx, jitExecIn, jitCapturesIn
import std/locks

import std/httpcore except HttpMethod

import ./request, ./response
import ./autolink

type
  HttpRouteType* = enum
    StaticRoute, DynamicRoute
  FastParamKind* = enum
    ## Single-trailing-param fast matcher. Mirrors the `RegexPatterns` classes
    ## in `autolink.nim` without invoking the regex engine: when a dynamic
    ## route has exactly one non-optional trailing placeholder with one of
    ## these classes, matching is a prefix compare plus a char-class scan.
    fpNone,       ## no fast matcher; use the regex JIT
    fpId,         ## `[0-9]+`
    fpSlug,       ## `[0-9A-Za-z-_]+`
    fpAnySlug,    ## `[0-9A-Za-z-_/]+`
    fpAlphaSlug,  ## `[A-Za-z-_]+`
    fpUuid,       ## `8-4-4-4-12` hex with dashes
    fpHex,        ## `[0-9a-fA-F]+`
    fpWord,       ## `\w+`
    fpWordDots,   ## `[\w.]+`
    fpAny         ## `.+` (any non-empty input without `\n`)
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

  # `{.acyclic.}`: routes and routers form a tree (tables/seqs/strings
  # procs only, no back-references), so the cycle collector can skip
  # them. This matters for threaded serving: ORC's cycle roots are
  # thread-local, so sharing a cyclic ref across workers corrupts the
  # collector (`unregisterCycle` SIGSEGV). Acyclic shared refs only do
  # refcount inc/dec; combined with the `GC_ref` pin at creation (count
  # never reaches zero for process-lifetime routes) concurrent lookups
  # under the router lock stay crash-free.
  HttpRoute* {.acyclic.} = ref object of RootObj
    path: string
      # The `path` is the original path string used to define the route.
    jit: CompiledJit
      # The JIT-compiled route pattern. The generated code is immutable,
      # so workers share it while executing on per-thread contexts.
    prog: Program
      # The compiled program, kept for the interpreter fallback when JIT
      # compilation is unavailable for the pattern or the platform.
    httpMethod: HttpMethod
      # The HTTP method (GET, POST, etc.) associated with this route.
    callback*: Callable
      ## The callback procedure that will be executed when this route is matched.
    case httpRouteType: HttpRouteType
      of DynamicRoute:
        routePatterns: OrderedTableRef[string, RoutePattern]
        fastPrefix: string
          # Static literal prefix before a single trailing param
          # (e.g. `"/users/"` for `"/users/{id:id}"`). Empty when `fpNone`.
        fastParamName: string
          # Param name fed from the fast matcher. Empty when `fpNone`.
        fastKind: FastParamKind
          # `fpNone` unless the route is a single non-optional trailing
          # placeholder with a fast-mirrorable class (see `matchFastClass`).
      else: discard
    case hasMiddleware: bool
      of true:
        middlewares: seq[Middleware]
      else: discard
    case hasAfterware: bool
      of true:
        afterwares: seq[Afterware]
      else: discard
  
  HttpRouteWs* {.acyclic.} = ref object of HttpRoute

  HttpRouterInstance* {.acyclic.} = ref object
    httpGet*, httpPost*, httpPut*, httpHead*,
      httpConnect*, httpDelete*, httpPatch*,
      httpTrace*, httpOptions*, httpErrors*: TableRef[string, HttpRoute]
    httpWS*: TableRef[string, HttpRouteWs]
    # Per-method dynamic-only route lists. Exact matches hit the tables
    # above; dynamic matching iterates only these (static routes never
    # enter the regex engine). Rebuilt under the router lock on
    # register/unregister/replace; readers use them under the same lock.
    dynGet*, dynPost*, dynPut*, dynHead*,
      dynConnect*, dynDelete*, dynPatch*,
      dynTrace*, dynOptions*: seq[HttpRoute]
    dynWS*: seq[HttpRouteWs]

  HttpRouterError* = object of CatchableError

var rw: Lock
initLock(rw)
# var Router*: HttpRouterInstance
# A thread local singleton instance of `HttpRouterInstance`
# that is used to register routes and error handlers.
# 
# Note that this is a thread-local variable, so each thread will
# have its own instance of the router. This allows for better
# performance in multi-threaded applications, as each thread
# can access its own router instance without any locking mechanism

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

proc matchFastClass*(kind: FastParamKind, s: string): bool {.inline.} =
  ## True when the whole of `s` matches the class. All classes require at
  ## least one char; `fpNone` never matches (falls back to the regex JIT).
  if s.len == 0: return false
  case kind
  of fpNone: return false
  of fpId:
    for c in s:
      if c < '0' or c > '9': return false
    return true
  of fpSlug:
    for c in s:
      if c notin {'0'..'9', 'A'..'Z', 'a'..'z', '-', '_'}: return false
    return true
  of fpAnySlug:
    for c in s:
      if c notin {'0'..'9', 'A'..'Z', 'a'..'z', '-', '_', '/'}: return false
    return true
  of fpAlphaSlug:
    for c in s:
      if c notin {'A'..'Z', 'a'..'z', '-', '_'}: return false
    return true
  of fpUuid:
    if s.len != 36: return false
    for i in 0 ..< 36:
      let c = s[i]
      if i in {8, 13, 18, 23}:
        if c != '-': return false
      elif c notin {'0'..'9', 'a'..'f', 'A'..'F'}: return false
    return true
  of fpHex:
    for c in s:
      if c notin {'0'..'9', 'a'..'f', 'A'..'F'}: return false
    return true
  of fpWord:
    for c in s:
      if c notin {'a'..'z', 'A'..'Z', '0'..'9', '_'}: return false
    return true
  of fpWordDots:
    for c in s:
      if c notin {'a'..'z', 'A'..'Z', '0'..'9', '_', '.'}: return false
    return true
  of fpAny:
    for c in s:
      if c == '\n': return false
    return true

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
    httpGet: TableRef[string, HttpRoute](),
    httpPost: TableRef[string, HttpRoute](),
    httpPut: TableRef[string, HttpRoute](),
    httpPatch: TableRef[string, HttpRoute](),
    httpHead: TableRef[string, HttpRoute](),
    httpDelete: TableRef[string, HttpRoute](),
    httpTrace: TableRef[string, HttpRoute](),
    httpOptions: TableRef[string, HttpRoute](),
    httpConnect: TableRef[string, HttpRoute](),
    httpWS: TableRef[string, HttpRouteWs](),
    httpErrors: TableRef[string, HttpRoute](),
    dynGet: @[], dynPost: @[], dynPut: @[], dynPatch: @[],
    dynHead: @[], dynDelete: @[], dynTrace: @[],
    dynOptions: @[], dynConnect: @[], dynWS: @[]
  )

proc deriveFastMatcher*(path: string,
    routeParams: seq[(string, bool)]): tuple[prefix, name: string,
    kind: FastParamKind] =
  ## Derive a regex-free matcher from the original route `path` when it is a
  ## single non-optional trailing placeholder with a fast-mirrorable class
  ## (e.g. `"/users/{id:id}"` → `("/users/", "id", fpId)`). Returns
  ## `("", "", fpNone)` for anything else (multi-param, mid-path or optional
  ## params, `semver`/custom classes), which keeps using the regex JIT.
  result = ("", "", fpNone)
  if routeParams.len != 1 or routeParams[0][1]: return
  let pname = routeParams[0][0]
  if path.len < 4 or path[^1] != '}': return
  let openIdx = path.rfind('{')
  if openIdx <= 0 or path.find('{') != openIdx: return
  let inner = path[openIdx + 1 .. ^2]
  let colon = inner.find(':')
  if colon <= 0 or inner[0 ..< colon] != pname: return
  let kind = case inner[colon + 1 .. ^1]
    of "id": fpId
    of "slug": fpSlug
    of "anySlug": fpAnySlug
    of "alphaSlug": fpAlphaSlug
    of "uuid": fpUuid
    of "hex": fpHex
    of "word": fpWord
    of "wordWithDots": fpWordDots
    of "any": fpAny
    else: fpNone
  if kind == fpNone: return
  result = (path[0 ..< openIdx], pname, kind)

proc newHttpRoute(autolinked: (string, string),
          httpMethod: HttpMethod, callback: Callable,
          routeParams: seq[(string, bool)] = @[]): HttpRoute =
  # Create a new `HttpRoute` (used for error handlers, never matched).
  # Fully initializes the `httpRouteType` discriminator; `prog`/`jit`
  # are compiled only when a regex pattern is present (error routes
  # use an empty pattern and are never matched via `matchRouteJIT`).
  let isDynamic = routeParams.len > 0
  result = HttpRoute(
    path: autolinked[1],
    httpMethod: httpMethod,
    callback: callback,
    httpRouteType: if isDynamic: DynamicRoute else: StaticRoute,
    hasMiddleware: false,
    hasAfterware: false
  )
  if autolinked[0].len > 0:
    let prog = regex.compile(autolinked[0])
    result.prog = prog
    result.jit = compileRegex(prog)
  if isDynamic:
    result.routePatterns = newOrderedTable[string, RoutePattern]()
    for (name, isOptional) in routeParams:
      result.routePatterns[name] = (key: name, reKey: "", isOptional: isOptional)
  GC_ref(result)

proc newHttpRoute(autolinked: (string, string),
                  httpMethod: HttpMethod, callback: Callable,
                  middlewares: seq[Middleware], afterwares: seq[Afterware],
                  routeParams: seq[(string, bool)] = @[]): HttpRoute =
  # Create a new `HttpRoute`
  let isDynamic = routeParams.len > 0
  result = HttpRoute(
    path: autolinked[1],
    httpMethod: httpMethod,
    callback: callback,
    httpRouteType: if isDynamic: DynamicRoute else: StaticRoute,
    hasMiddleware: middlewares.len > 0,
    hasAfterware: afterwares.len > 0
  )
  if isDynamic:
    let (fastPrefix, fastName, fastKind) =
      deriveFastMatcher(autolinked[1], routeParams)
    result.fastPrefix = fastPrefix
    result.fastParamName = fastName
    result.fastKind = fastKind
    result.routePatterns = newOrderedTable[string, RoutePattern]()
    for (name, isOptional) in routeParams:
      result.routePatterns[name] = (key: name, reKey: "", isOptional: isOptional)
    if fastKind == fpNone:
      # Only patterns the fast matcher cannot mirror need the regex engine.
      # Static routes never enter `matchRouteJIT`, so they skip compilation
      # entirely (faster registration, no JIT memory).
      let prog = regex.compile(autolinked[0])
      result.prog = prog
      result.jit = compileRegex(prog)
  if result.hasMiddleware: result.middlewares = middlewares
  if result.hasAfterware:  result.afterwares = afterwares
  # Pin the route cell: workers share route objects across threads and
  # Nim refcounting is not atomic, so concurrent copies could otherwise
  # drift the count down to a premature zero. The pin keeps the count
  # above zero for the process lifetime (see newHttpRoute above).
  GC_ref(result)


proc newWsRoute(autolinked: (string, string), httpMethod: HttpMethod, callback: Callable,
                middlewares: seq[Middleware], afterwares: seq[Afterware],
                routeParams: seq[(string, bool)] = @[]): HttpRouteWs =
  # Create a new `HttpRoute` for WebSocket
  let isDynamic = routeParams.len > 0
  result = HttpRouteWs(
    path: autolinked[1],
    httpMethod: httpMethod,
    callback: callback,
    httpRouteType: if isDynamic: DynamicRoute else: StaticRoute,
    hasMiddleware: middlewares.len > 0,
    hasAfterware: afterwares.len > 0
  )
  if isDynamic:
    let (fastPrefix, fastName, fastKind) =
      deriveFastMatcher(autolinked[1], routeParams)
    result.fastPrefix = fastPrefix
    result.fastParamName = fastName
    result.fastKind = fastKind
    result.routePatterns = newOrderedTable[string, RoutePattern]()
    for (name, isOptional) in routeParams:
      result.routePatterns[name] = (key: name, reKey: "", isOptional: isOptional)
    if fastKind == fpNone:
      let prog = regex.compile(autolinked[0])
      result.prog = prog
      result.jit = compileRegex(prog)
  if result.hasMiddleware: result.middlewares = middlewares
  if result.hasAfterware:  result.afterwares = afterwares
  # Pin the route cell (see newHttpRoute above).
  GC_ref(result)

template addDynSlot(dynRoutes, routeObject) =
  ## Append a freshly registered dynamic route to its per-method list.
  if routeObject.httpRouteType == DynamicRoute:
    dynRoutes.add(routeObject)

template syncDynSlot(dynRoutes, routePath, routeObject) =
  ## Keep a per-method dynamic list in sync with its exact-match table
  ## after an explicit overwrite (`replaceRoute`). Works for both
  ## `seq[HttpRoute]` and `seq[HttpRouteWs]`.
  block:
    var foundIdx = -1
    for i in 0 ..< dynRoutes.len:
      if dynRoutes[i].path == routePath:
        foundIdx = i
        break
    if routeObject.httpRouteType == DynamicRoute:
      if foundIdx >= 0: dynRoutes[foundIdx] = routeObject
      else: dynRoutes.add(routeObject)
    elif foundIdx >= 0:
      dynRoutes.del(foundIdx)

template removeDynSlot(dynRoutes, routePath) =
  ## Drop `routePath` from a per-method dynamic list (no-op when absent).
  block:
    for i in 0 ..< dynRoutes.len:
      if dynRoutes[i].path == routePath:
        dynRoutes.del(i)
        break

proc registerRoute*(router: HttpRouterInstance,
  autolinked: sink (string, string),
  httpMethod: HttpMethod,
  callback: Callable,
  middlewares: seq[Middleware] = @[],
  afterwares: seq[Afterware] = @[],
  isWebSocket = false,
  routeParams: seq[(string, bool)] = @[]
) =
  ## Register a new `Route` in the `HttpRouterInstance` based on the given parameters
  withLock rw:
    let path = autolinked[1] # the original path string used to define the route
    if isWebSocket:
      let routeObject = newWsRoute(autolinked, HttpGet, callback, middlewares, afterwares, routeParams)
      if not router.httpWS.hasKey(path):
        router.httpWS[path] = routeObject
        addDynSlot(router.dynWS, routeObject)
    else:
      let routeObject =
        newHttpRoute(autolinked, httpMethod, callback,
                middlewares, afterwares, routeParams)
      case httpMethod
      of HttpGet:
        if not router.httpGet.hasKey(path):
          router.httpGet[path] = routeObject
          addDynSlot(router.dynGet, routeObject)
      of HttpPost:
        if not router.httpPost.hasKey(path):
          router.httpPost[path] = routeObject
          addDynSlot(router.dynPost, routeObject)
      of HttpPut:
        if not router.httpPut.hasKey(path):
          router.httpPut[path] = routeObject
          addDynSlot(router.dynPut, routeObject)
      of HttpPatch:
        if not router.httpPatch.hasKey(path):
          router.httpPatch[path] = routeObject
          addDynSlot(router.dynPatch, routeObject)
      of HttpHead:
        if not router.httpHead.hasKey(path):
          router.httpHead[path] = routeObject
          addDynSlot(router.dynHead, routeObject)
      of HttpDelete:
        if not router.httpDelete.hasKey(path):
          router.httpDelete[path] = routeObject
          addDynSlot(router.dynDelete, routeObject)
      of HttpTrace:
        if not router.httpTrace.hasKey(path):
          router.httpTrace[path] = routeObject
          addDynSlot(router.dynTrace, routeObject)
      of HttpOptions:
        if not router.httpOptions.hasKey(path):
          router.httpOptions[path] = routeObject
          addDynSlot(router.dynOptions, routeObject)
      of HttpConnect:
        if not router.httpConnect.hasKey(path):
          router.httpConnect[path] = routeObject
          addDynSlot(router.dynConnect, routeObject)

proc registerRoute*(router: HttpRouterInstance, path: string,
                httpMethod: HttpMethod, callback: Callable,
                middlewares: seq[Middleware] = @[],
                afterwares: seq[Afterware] = @[]) =
  ## Register a new Route in the `HttpRouterInstance` based on the given parameters
  let autolinked = autolinkController(path, httpMethod)
  let rp = if autolinked.params.isSome(): autolinked.params.get() else: @[]
  registerRoute(router, (autolinked[1], autolinked[2]), httpMethod,
              callback, middlewares, afterwares, routeParams = rp)

proc unregisterRoute*(router: HttpRouterInstance,
  autolinked: sink (string, string),
  httpMethod: HttpMethod
) =
  ## Remove a previously registered `Route` from the `HttpRouterInstance`.
  ## The `autolinked` tuple must carry the same original path string used
  ## at registration time (for example the tuple returned by
  ## `autolinkController`). Removing an unknown route is a no-op.
  withLock rw:
    let path = autolinked[1] # the original path string used to define the route
    case httpMethod
    of HttpGet:
      if router.httpGet.hasKey(path):
        router.httpGet.del(path)
        removeDynSlot(router.dynGet, path)
    of HttpPost:
      if router.httpPost.hasKey(path):
        router.httpPost.del(path)
        removeDynSlot(router.dynPost, path)
    of HttpPut:
      if router.httpPut.hasKey(path):
        router.httpPut.del(path)
        removeDynSlot(router.dynPut, path)
    of HttpPatch:
      if router.httpPatch.hasKey(path):
        router.httpPatch.del(path)
        removeDynSlot(router.dynPatch, path)
    of HttpHead:
      if router.httpHead.hasKey(path):
        router.httpHead.del(path)
        removeDynSlot(router.dynHead, path)
    of HttpDelete:
      if router.httpDelete.hasKey(path):
        router.httpDelete.del(path)
        removeDynSlot(router.dynDelete, path)
    of HttpTrace:
      if router.httpTrace.hasKey(path):
        router.httpTrace.del(path)
        removeDynSlot(router.dynTrace, path)
    of HttpOptions:
      if router.httpOptions.hasKey(path):
        router.httpOptions.del(path)
        removeDynSlot(router.dynOptions, path)
    of HttpConnect:
      if router.httpConnect.hasKey(path):
        router.httpConnect.del(path)
        removeDynSlot(router.dynConnect, path)

proc unregisterWsRoute*(router: HttpRouterInstance, path: string) =
  ## Remove a previously registered WebSocket route. No-op when missing.
  withLock rw:
    if router.httpWS.hasKey(path):
      router.httpWS.del(path)
      removeDynSlot(router.dynWS, path)

proc hasRoute*(router: HttpRouterInstance, path: string,
    httpMethod: HttpMethod): bool =
  ## True when an exact path is registered for `httpMethod`.
  ## Dynamic-pattern matches are not considered; use `checkExists` for those.
  withLock rw:
    case httpMethod
    of HttpGet: result = router.httpGet.hasKey(path)
    of HttpPost: result = router.httpPost.hasKey(path)
    of HttpPut: result = router.httpPut.hasKey(path)
    of HttpPatch: result = router.httpPatch.hasKey(path)
    of HttpHead: result = router.httpHead.hasKey(path)
    of HttpDelete: result = router.httpDelete.hasKey(path)
    of HttpTrace: result = router.httpTrace.hasKey(path)
    of HttpOptions: result = router.httpOptions.hasKey(path)
    of HttpConnect: result = router.httpConnect.hasKey(path)

proc replaceRoute*(router: HttpRouterInstance,
  autolinked: sink (string, string),
  httpMethod: HttpMethod,
  callback: Callable,
  middlewares: seq[Middleware] = @[],
  afterwares: seq[Afterware] = @[],
  isWebSocket = false,
  routeParams: seq[(string, bool)] = @[]
) =
  ## Explicit overwrite registration. Unlike `registerRoute` (which keeps
  ## the first registration and ignores duplicates), this always replaces.
  withLock rw:
    let path = autolinked[1]
    if isWebSocket:
      let wsRoute = newWsRoute(autolinked, HttpGet,
        callback, middlewares, afterwares, routeParams)
      router.httpWS[path] = wsRoute
      syncDynSlot(router.dynWS, path, wsRoute)
      return
    let routeObject = newHttpRoute(autolinked, httpMethod, callback,
      middlewares, afterwares, routeParams)
    case httpMethod
    of HttpGet:
      router.httpGet[path] = routeObject
      syncDynSlot(router.dynGet, path, routeObject)
    of HttpPost:
      router.httpPost[path] = routeObject
      syncDynSlot(router.dynPost, path, routeObject)
    of HttpPut:
      router.httpPut[path] = routeObject
      syncDynSlot(router.dynPut, path, routeObject)
    of HttpPatch:
      router.httpPatch[path] = routeObject
      syncDynSlot(router.dynPatch, path, routeObject)
    of HttpHead:
      router.httpHead[path] = routeObject
      syncDynSlot(router.dynHead, path, routeObject)
    of HttpDelete:
      router.httpDelete[path] = routeObject
      syncDynSlot(router.dynDelete, path, routeObject)
    of HttpTrace:
      router.httpTrace[path] = routeObject
      syncDynSlot(router.dynTrace, path, routeObject)
    of HttpOptions:
      router.httpOptions[path] = routeObject
      syncDynSlot(router.dynOptions, path, routeObject)
    of HttpConnect:
      router.httpConnect[path] = routeObject
      syncDynSlot(router.dynConnect, path, routeObject)

#
# Verb helpers
#
# Thin wrappers around `registerRoute` so routes read naturally:
# ```nim
# router.get("/hello", myHandler)
# router.post("/users", createUser, middlewares = @[auth])
# ```
proc get*(router: HttpRouterInstance, path: string, callback: Callable,
        middlewares: seq[Middleware] = @[],
        afterwares: seq[Afterware] = @[]) =
  ## Register a `GET` route. Shortcut for `registerRoute(path, HttpGet, ...)`.
  router.registerRoute(path, HttpGet, callback, middlewares, afterwares)

proc post*(router: HttpRouterInstance, path: string, callback: Callable,
        middlewares: seq[Middleware] = @[],
        afterwares: seq[Afterware] = @[]) =
  ## Register a `POST` route. Shortcut for `registerRoute(path, HttpPost, ...)`.
  router.registerRoute(path, HttpPost, callback, middlewares, afterwares)

proc put*(router: HttpRouterInstance, path: string, callback: Callable,
        middlewares: seq[Middleware] = @[],
        afterwares: seq[Afterware] = @[]) =
  ## Register a `PUT` route. Shortcut for `registerRoute(path, HttpPut, ...)`.
  router.registerRoute(path, HttpPut, callback, middlewares, afterwares)

proc patch*(router: HttpRouterInstance, path: string, callback: Callable,
        middlewares: seq[Middleware] = @[],
        afterwares: seq[Afterware] = @[]) =
  ## Register a `PATCH` route. Shortcut for `registerRoute(path, HttpPatch, ...)`.
  router.registerRoute(path, HttpPatch, callback, middlewares, afterwares)

proc head*(router: HttpRouterInstance, path: string, callback: Callable,
        middlewares: seq[Middleware] = @[],
        afterwares: seq[Afterware] = @[]) =
  ## Register a `HEAD` route. Shortcut for `registerRoute(path, HttpHead, ...)`.
  router.registerRoute(path, HttpHead, callback, middlewares, afterwares)

proc delete*(router: HttpRouterInstance, path: string, callback: Callable,
        middlewares: seq[Middleware] = @[],
        afterwares: seq[Afterware] = @[]) =
  ## Register a `DELETE` route. Shortcut for `registerRoute(path, HttpDelete, ...)`.
  router.registerRoute(path, HttpDelete, callback, middlewares, afterwares)

proc trace*(router: HttpRouterInstance, path: string, callback: Callable,
        middlewares: seq[Middleware] = @[],
        afterwares: seq[Afterware] = @[]) =
  ## Register a `TRACE` route. Shortcut for `registerRoute(path, HttpTrace, ...)`.
  router.registerRoute(path, HttpTrace, callback, middlewares, afterwares)

proc options*(router: HttpRouterInstance, path: string, callback: Callable,
        middlewares: seq[Middleware] = @[],
        afterwares: seq[Afterware] = @[]) =
  ## Register an `OPTIONS` route. Shortcut for `registerRoute(path, HttpOptions, ...)`.
  router.registerRoute(path, HttpOptions, callback, middlewares, afterwares)

proc connect*(router: HttpRouterInstance, path: string, callback: Callable,
        middlewares: seq[Middleware] = @[],
        afterwares: seq[Afterware] = @[]) =
  ## Register a `CONNECT` route. Shortcut for `registerRoute(path, HttpConnect, ...)`.
  router.registerRoute(path, HttpConnect, callback, middlewares, afterwares)

proc ws*(router: HttpRouterInstance, path: string, callback: Callable,
        middlewares: seq[Middleware] = @[],
        afterwares: seq[Afterware] = @[]) =
  ## Register a WebSocket route (`GET` + `isWebSocket`).
  ## Shortcut for `registerRoute(..., HttpGet, ..., isWebSocket = true)`.
  let autolinked = autolinkController(path, HttpGet, isWebSocket = true)
  let rp = if autolinked.params.isSome(): autolinked.params.get() else: @[]
  router.registerRoute((autolinked[1], autolinked[2]), HttpGet,
              callback, middlewares, afterwares,
              isWebSocket = true, routeParams = rp)

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
  var paramsBracket = newNimNode(nnkBracket)
  if autolinked.params.isSome:
    for (name, isOpt) in autolinked.params.get():
      paramsBracket.add(nnkTupleConstr.newTree(newLit(name), newLit(isOpt)))
  let paramsLit = newTree(nnkPrefix, ident"@", paramsBracket)

  if closureHandle.isNil:
    queuedRoutes[autolinked.handleName] =
      newCall(
        ident"registerRoute",
        newDotExpr(ident"App", ident"router"),
        # ident"Router",
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
        ),
        nnkExprEqExpr.newTree(ident"routeParams", paramsLit)
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

var threadJitCtxs {.threadvar.}: Table[int, ptr JitCtx]
  ## The calling thread's private JIT execution contexts (backtrack stack
  ## + capture buffer), one per capture-slot count. Sharing compiled route
  ## code across workers is safe because every thread matches through its
  ## own contexts. Contexts cannot be shared across slot counts: the
  ## generated code derives the stack base from the stack size baked in
  ## at compile time, so entry layouts must agree.
var lastJitSlots {.threadvar.}: int
  ## Fast-path cache for `getThreadJitCtx`: most requests hit routes with
  ## the same slot count in a row, so a single compare skips the table.
var lastJitCtx {.threadvar.}: ptr JitCtx
var lastJitReady {.threadvar.}: bool

proc getThreadJitCtx(slotsNeeded: int): ptr JitCtx =
  ## Return the calling thread's JIT context for `slotsNeeded` capture
  ## slots, allocating and caching it on first use.
  if lastJitReady and lastJitSlots == slotsNeeded and lastJitCtx != nil:
    return lastJitCtx
  let found = threadJitCtxs.getOrDefault(slotsNeeded, nil)
  if found != nil:
    lastJitSlots = slotsNeeded
    lastJitCtx = found
    lastJitReady = true
    return found
  let ctx = newJitCtx(slotsNeeded)
  if ctx != nil:
    threadJitCtxs[slotsNeeded] = ctx
    lastJitSlots = slotsNeeded
    lastJitCtx = ctx
    lastJitReady = true
  ctx

proc matchRouteJIT*(route: HttpRoute, requestPath: string,
                    params: var Table[string, string]): bool =
  ## Full-match an anchored route pattern against `requestPath`, extracting
  ## dynamic params into `params`.
  ##
  ## Single-trailing-param routes (`/users/{id:id}`) take a regex-free fast
  ## path: a prefix compare plus a char-class scan. Everything else runs on
  ## the regex JIT with the calling thread's private context, so concurrent
  ## workers can match the same route object while holding only the router
  ## read lock. Falls back to a per-call interpreter VM when JIT compilation
  ## is unavailable for the pattern or the platform.
  if route.httpRouteType == DynamicRoute and route.fastKind != fpNone:
    if requestPath.len > route.fastPrefix.len and
        requestPath.startsWith(route.fastPrefix):
      let val = requestPath[route.fastPrefix.len .. ^1]
      if matchFastClass(route.fastKind, val):
        params[route.fastParamName] = val
        return true
    return false
  if route.jit.fn != nil:
    let ctx = getThreadJitCtx(route.jit.numSlots)
    if ctx != nil and ctx.capsBase != nil:
      if jitExecIn(route.jit, ctx, requestPath, 0) == requestPath.len:
        if route.httpRouteType == DynamicRoute:
          # Read captures straight from the context buffer instead of
          # `jitCapturesIn` (which copies them into a fresh seq per call).
          let caps = cast[ptr UncheckedArray[int]](ctx.capsBase)
          var idx = 1
          for name, _ in route.routePatterns:
            let slot = (idx - 1) * 2
            if slot + 1 < ctx.numSlots:
              let lo = caps[slot]
              let hi = caps[slot + 1]
              if lo >= 0 and hi >= lo:
                params[name] = requestPath[lo ..< hi]
            inc idx
        return true
      return false
    # Context allocation failed — fall through to the interpreter.
  if route.httpRouteType != DynamicRoute:
    # Static routes never compile a pattern; without JIT there is
    # nothing to match with.
    return false
  var vm = regex.initRegexVM(route.prog)
  defer: regex.closeRegexVM(vm)
  let m = vm.find(requestPath)
  if m.matched and m.start == 0 and m.stop == requestPath.len:
    if route.httpRouteType == DynamicRoute:
      var idx = 1
      for name, _ in route.routePatterns:
        let g = m.group(idx)
        if g.matched:
          params[name] = g.str(requestPath)
        inc idx
    return true
  return false

macro searchRoute(httpMethod: static string) =
  # `httpMethod` is the exact-match table name (`"httpGet"`); the dynamic
  # list is the same suffix on `"dyn"` (`"dynGet"`).
  let verb = ident httpMethod
  let dynVerb = ident("dyn" & httpMethod[4 .. ^1])
  result = newStmtList()
  add result, quote do:
    let foundRoute = router.`verb`.getOrDefault(requestPath, nil)
    if likely(foundRoute != nil):
      result.route = foundRoute
    else:
      for r in router.`dynVerb`:
        if matchRouteJIT(r, requestPath, result.params):
          result.route = r
          break

macro searchRouteWs*() =
  ## Search for a WebSocket route
  result = newStmtList()
  add result, quote do:
    if router.httpWS.hasKey(requestPath):
      result.route = router.httpWS[requestPath]
    else:
      for r in router.dynWS:
        if matchRouteJIT(r, requestPath, result.params):
          result.route = r
          break

type
  RouteCheckResult* = tuple[exists: bool, route: HttpRoute, params: Table[string, string]]

proc checkExists*(router: var HttpRouterInstance,
            requestPath: string, httpMethod: HttpMethod): RouteCheckResult =
  ## Check if a route exists for the given request path and HTTP method.
  ## `HEAD` falls back to `GET` when no explicit `HEAD` route is
  ## registered (standard HTTP semantics: same headers, no body).
  withLock rw:
    case httpMethod
      of HttpGet:     searchRoute("httpGet")
      of HttpPost:    searchRoute("httpPost")
      of HttpPut:     searchRoute("httpPut")
      of HttpPatch:   searchRoute("httpPatch")
      of HttpHead:
        searchRoute("httpHead")
        if result.route.isNil:
          # Fallback to GET table (exact + dynamic).
          result.route = router.httpGet.getOrDefault(requestPath, nil)
          if result.route.isNil:
            for r in router.dynGet:
              if matchRouteJIT(r, requestPath, result.params):
                result.route = r
                break
      of HttpDelete:  searchRoute("httpDelete")
      of HttpTrace:   searchRoute("httpTrace")
      of HttpOptions: searchRoute("httpOptions")
      of HttpConnect: searchRoute("httpConnect")
    result.exists =
      likely(result.route != nil)

proc allowedMethods*(router: var HttpRouterInstance,
    requestPath: string): seq[HttpMethod] =
  ## Returns every method with a route matching `requestPath`
  ## (exact match first, then dynamic patterns). Used for `405`
  ## handling and `Allow` headers. Single lock, no nested `checkExists`.
  withLock rw:
    template tryTable(tbl, dynTbl, meth: untyped) =
      block:
        var matched = false
        if tbl.hasKey(requestPath):
          matched = true
        else:
          var tmp = initTable[string, string]()
          for r in dynTbl:
            if matchRouteJIT(r, requestPath, tmp):
              matched = true
              break
        if matched:
          result.add(meth)
    tryTable(router.httpGet, router.dynGet, HttpGet)
    tryTable(router.httpPost, router.dynPost, HttpPost)
    tryTable(router.httpPut, router.dynPut, HttpPut)
    tryTable(router.httpPatch, router.dynPatch, HttpPatch)
    tryTable(router.httpHead, router.dynHead, HttpHead)
    tryTable(router.httpDelete, router.dynDelete, HttpDelete)
    tryTable(router.httpTrace, router.dynTrace, HttpTrace)
    tryTable(router.httpOptions, router.dynOptions, HttpOptions)
    tryTable(router.httpConnect, router.dynConnect, HttpConnect)

proc isMethodNotAllowed*(router: var HttpRouterInstance,
    requestPath: string, httpMethod: HttpMethod): bool =
  ## True when `requestPath` exists for another method but not for
  ## `httpMethod` (i.e. the correct status is `405`, not `404`).
  ## `HEAD` is never "not allowed" when `GET` exists (fallback).
  let hit = router.checkExists(requestPath, httpMethod)
  if hit.exists:
    return false
  if httpMethod == HttpHead:
    var tmpGet = router.checkExists(requestPath, HttpGet)
    if tmpGet.exists:
      return false
  let allowed = router.allowedMethods(requestPath)
  result = allowed.len > 0

proc checkWsExists*(router: var HttpRouterInstance, requestPath: string): RouteCheckResult =
  ## Check if a WebSocket route exists for the given request path
  withLock rw:
    searchRouteWs()
    result.exists = likely(result.route != nil)

#
# Middleware API
#
proc getMiddlewares*(route: HttpRoute): seq[Middleware] =
  ## Returns the route middlewares, or `@[]` when none.
  ## (`getMiddlewares` is public for introspection; the request path
  ## uses `resolveMiddleware` directly.)
  if route.hasMiddleware:
    result = route.middlewares

proc getAfterwares*(route: HttpRoute): seq[Afterware] =
  ## Returns the route afterwares, or `@[]` when none.
  if route.hasAfterware:
    result = route.afterwares

proc resolveMiddleware*(route: HttpRoute,
    req: var Request, res: var Response): HttpCode =
  ## Checks a `route` if has any implemented middlewares
  if route.hasMiddleware:
    if res.middlewareIndex > route.middlewares.high:
      return Http204
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
  ## has been made. Returns `Http204` when the chain completes
  ## (including when there is no afterware), so callers can treat
  ## any non-`204` as a short-circuit.
  if route.hasAfterware:
    if res.afterwareIndex > route.afterwares.high:
      return Http204
    result = route.afterwares[res.afterwareIndex](req, res)
    case result
    of Http204:
      inc res.afterwareIndex
      if route.afterwares.high >= res.afterwareIndex:
        return route.resolveAfterware(req, res)
      return result
    else: return # result
  result = Http204


#
# Error Handles
#
proc errorHandler*(router: HttpRouterInstance,
    code: HttpCode, callback: Callable) =
  ## Register an error handler for a specific HTTP status code.
  ## Stores under the specific key (`"404"`, `"500"`, ...) and also under
  ## the generic `"4xx"` / `"5xx"` fallback (first registration wins for
  ## the generic slot, so `initRouterErrorHandlers` stays stable).
  ## Unknown codes outside 400..599 are stored under their numeric key only.
  let httpRoute = newHttpRoute(("", $code.int), HttpGet, callback)
  let key = $code.int
  router.httpErrors[key] = httpRoute
  if code.int in 400 .. 499:
    if not router.httpErrors.hasKey("4xx"):
      router.httpErrors["4xx"] = httpRoute
  elif code.int in 500 .. 599:
    if not router.httpErrors.hasKey("5xx"):
      router.httpErrors["5xx"] = httpRoute

proc hasErrorHandler*(router: HttpRouterInstance, code: HttpCode): bool =
  ## True when a specific or generic handler exists for `code`.
  let key = $code.int
  if router.httpErrors.hasKey(key):
    return true
  if code.int in 400 .. 499:
    return router.httpErrors.hasKey("4xx")
  if code.int in 500 .. 599:
    return router.httpErrors.hasKey("5xx")
  false

proc callError*(router: HttpRouterInstance,
    code: HttpCode,
    req: var Request, res: var Response): bool {.discardable.} =
  ## Runs the most specific handler for `code` (specific key, then
  ## `"4xx"` / `"5xx"` fallback). Returns true when a handler ran,
  ## false when none is registered (never raises).
  let key = $code.int
  if router.httpErrors.hasKey(key):
    router.httpErrors[key].callback(req, res)
    return true
  if code.int in 400 .. 499 and router.httpErrors.hasKey("4xx"):
    router.httpErrors["4xx"].callback(req, res)
    return true
  if code.int in 500 .. 599 and router.httpErrors.hasKey("5xx"):
    router.httpErrors["5xx"].callback(req, res)
    return true
  false

when defined supraMicroservice:
  proc call4xx*(router: HttpRouterInstance,
                req: ptr Request, res: ptr Response) {.discardable.} =
    ## Run the `4xx` callback. Safe no-op when none is registered
    ## (never raises `KeyError`).
    if router.httpErrors.hasKey("4xx"):
      router.httpErrors["4xx"].callback(req, res)

  proc call5xx*(router: HttpRouterInstance,
                req: ptr Request, res: ptr Response) {.discardable.} =
    ## Run the `5xx` callback. Safe no-op when none is registered.
    if router.httpErrors.hasKey("5xx"):
      router.httpErrors["5xx"].callback(req, res)

  proc callError*(router: HttpRouterInstance, code: HttpCode,
                req: ptr Request, res: ptr Response): bool {.discardable.} =
    ## Ptr overload for microservice mode. Tries specific key, then
    ## `"4xx"` / `"5xx"` fallback. Returns true when a handler ran.
    let key = $code.int
    if router.httpErrors.hasKey(key):
      router.httpErrors[key].callback(req, res)
      return true
    if code.int in 400 .. 499 and router.httpErrors.hasKey("4xx"):
      router.httpErrors["4xx"].callback(req, res)
      return true
    if code.int in 500 .. 599 and router.httpErrors.hasKey("5xx"):
      router.httpErrors["5xx"].callback(req, res)
      return true
    false
elif compileOption("app", "lib"):
  proc call4xx*(router: HttpRouterInstance,
                req: ptr Request, res: ptr Response) {.cdecl, discardable.} =
    ## Run the `4xx` callback. Safe no-op when none is registered.
    if router.httpErrors.hasKey("4xx"):
      router.httpErrors["4xx"].callback(req, res)

  proc call5xx*(router: HttpRouterInstance,
                req: ptr Request, res: ptr Response) {.cdecl, discardable.} =
    ## Run the `5xx` callback. Safe no-op when none is registered.
    if router.httpErrors.hasKey("5xx"):
      router.httpErrors["5xx"].callback(req, res)

  proc callError*(router: HttpRouterInstance, code: HttpCode,
                req: ptr Request, res: ptr Response): bool {.cdecl, discardable.} =
    ## Ptr overload for `--app:lib` mode. See `var` overload above.
    let key = $code.int
    if router.httpErrors.hasKey(key):
      router.httpErrors[key].callback(req, res)
      return true
    if code.int in 400 .. 499 and router.httpErrors.hasKey("4xx"):
      router.httpErrors["4xx"].callback(req, res)
      return true
    if code.int in 500 .. 599 and router.httpErrors.hasKey("5xx"):
      router.httpErrors["5xx"].callback(req, res)
      return true
    false
else:
  proc call4xx*(router: HttpRouterInstance,
                req: var Request, res: var Response) {.discardable.} =
    ## Run the `4xx` callback. Safe no-op when none is registered
    ## (never raises `KeyError`).
    if router.httpErrors.hasKey("4xx"):
      router.httpErrors["4xx"].callback(req, res)

  proc call5xx*(router: HttpRouterInstance,
                req: var Request, res: var Response) {.discardable.} =
    ## Run the `5xx` callback. Safe no-op when none is registered.
    if router.httpErrors.hasKey("5xx"):
      router.httpErrors["5xx"].callback(req, res)

template initRouterErrorHandlers* =
  ## Initialize default error handlers for the router. This is called during
  ## application startup to ensure that there is always a default error handler for HTTP 4xx errors
  App.router.errorHandler(Http404, errors.get4xx)
