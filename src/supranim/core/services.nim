#
# Supranim is a high-performance web framework for building
# web applications and microservices in Nim
# 
#   (c) 2026 LGPL-v3-or-later License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#

import std/[os, macros, macrocache, tables, sequtils,
          critbits, strutils, random, parseopt, options]

import pkg/checksums/md5
import pkg/threading/once
import pkg/threading/channels
import pkg/openparser/[yaml, json]

import pkg/kapsis/framework
import pkg/kapsis/interactive/prompts

import pkg/supranim/application
import pkg/supranim/network/websocket
import pkg/supranim/core/[paths, autolink, router]

from std/net import Port, `$`
from std/httpcore import HttpCode
from pkg/powpow import HttpMethod

export macros, macrocache, tables, once, options
export yaml, json

type
  ServiceType* = enum
    ## Defines Supranim Service types
    Global = "Global"
      ## Namespace-style service without an instance type: only the
      ## `state`/`api` blocks are emitted, no `get<Name>Instance`
      ## accessor is generated (unlike `Singleton`)
    Singleton = "Singleton"
      ## Defines a Singleton service as part of the main application
    ChannelService = "ChannelService"
      ## Deprecated alias of `ThreadService`. Channel-based job-thread
      ## services communicate with the main app via `threading/channels`
    WebService = "WebService"
      ## REST API Service Provider that connects over TCP/IP.
      ## Runs embedded in an application thread, or compiled
      ## as a standalone microservice binary (`isMainModule`).
      ## With a `ws do:` block it runs a standalone WebSocket
      ## server (powpow `WsServer`) instead, in thread or standalone mode.
    UnixService = "UnixService"
      ## HTTP Service Provider over a Unix domain socket.
      ## Same dual mode as `WebService` (embedded thread or
      ## standalone binary), ideal for fast local IPC.
    ThreadService = "ThreadService"
      ## Job-thread service: runs user code for as long as it wants
      ## in its own thread and talks to the main application through
      ## the application-owned `Chan[ServiceMsg]`
      ## (see `core/application`). Cannot be built standalone.
    ThreadPoolService = "ThreadPoolService"
      ## Job-pool service over `supranim_tasks` `TaskManager`: N
      ## anonymous workers for CPU-bound jobs plus delayed, repeating
      ## and wall-clock scheduled tasks. No worker body and no
      ## channel plumbing of its own (unlike `ThreadService`). Jobs
      ## run on workers; callbacks run serialized on the pool
      ## dispatch thread, never on the main thread. Cannot be built
      ## standalone.
      # UdpService = "UdpService"
      #   # Defines a standalone Service that connects over UDP
      # CoAPService = "CoAPService"
      #   # Defines a standalone Service
      #   # based on CoAP (Constrained Application Protocol)
      #   # https://coap.space


  HttpRouteMeta* = object
    path*, regex*: string
    `method`*: HttpMethod
    description*: string
    public*: bool = true

  HttpRouteVerbs* = CritBitTree[HttpRouteMeta]
  HttpRoutes* = CritBitTree[HttpRouteVerbs]
    ## This table is used to return an index of
    ## all routes at `GET /` request

  HttpServiceIndex* = ref object
    ## Used to generate a readonly JSON Index
    ## available at `GET /` request.
    ## 
    ## Provides meta data for available routes,
    ## authorization type, service version and compilation time.
    description: string
    routes: HttpRoutes
    authorization: string = "ApiKey"
    compilation_time: string = CompileDate & "-" & CompileTime
      # Store compilation time (in UTC)
    release_mode: bool

  HttpService* = object
    ## When the service type is either a `UnixService` or `WebService`.
    ## By default the generated `HttpService` is always private
    ## and cannot be accessed without an API key
    private: bool
    privateKey: string
    threads: uint = 1

  SingletonService* = object

  ServiceProvider* = object
    serviceType*: ServiceType
    name*, description*, author*, version*: string
    host*: string = "0.0.0.0"
      ## Bind address for `WebService` (TCP) listeners
    port*: int = 0
      ## TCP port for `WebService`. `0` selects the default:
      ## `3000` standalone, `9000` embedded thread
    threads*: int = 1
      ## Server worker threads for standalone `WebService` (`> 1`
      ## uses the multi-threaded powpow server)
    queueSize*: int = 64
      ## `Chan[ServiceMsg]` capacity for `ThreadService`
    timeoutMs*: int = 2000
      ## Default request/reply timeout hint for `ThreadService` api handles
    poolSize*: int = 4
      ## Worker count for `ThreadPoolService` (mirrors powpow's default)
    socketPath*: string = ""
      ## Unix domain socket path for `UnixService`
    socketMode*: int = 0o660
      ## File permission bits for the `UnixService` socket
    autoStart*: bool = true
      ## Whether the service starts automatically with the application
      ## (`ThreadService` / embedded `WebService` / `UnixService` threads)
    # case serviceType*: ServiceType
    # of UnixService, WebService:
    #   httpService: HttpService
    #   router: type(Router)
    # of Singleton:
    #   singletonService: SingletonService

  ServiceManagerObject = object
    data: int

var
  StaticService {.compileTime.}: ServiceProvider
  httpRouteMetaObj {.compileTime.}: NimNode
  index* {.compileTime.} = genSym(nskVar, "IndexRoute")
  routerInstance* {.compileTime.} = genSym(nskVar, "RouterInstance")

proc setServiceField(fieldName: string, value: NimNode) {.compileTime.} =
  ## Assign a top-level `field = value` pair onto `StaticService`,
  ## validating it against the current service type.
  case fieldName
  of "description":
    value.expectKind(nnkStrLit)
    StaticService.description = value.strVal
  of "author":
    value.expectKind(nnkStrLit)
    StaticService.author = value.strVal
  of "version":
    value.expectKind(nnkStrLit)
    StaticService.version = value.strVal
  of "autoStart":
    StaticService.autoStart = value.eqIdent"true"
  of "host":
    if StaticService.serviceType notin {WebService}:
      error("Service field `host` is only supported by `WebService`", value)
    value.expectKind(nnkStrLit)
    StaticService.host = value.strVal
  of "port":
    if StaticService.serviceType notin {WebService}:
      error("Service field `port` is only supported by `WebService`", value)
    StaticService.port = int(value.intVal)
  of "threads":
    if StaticService.serviceType notin {WebService, UnixService}:
      error("Service field `threads` is only supported by web services", value)
    StaticService.threads = int(value.intVal)
  of "queueSize":
    if StaticService.serviceType notin {ThreadService, ChannelService}:
      error("Service field `queueSize` is only supported by `ThreadService`", value)
    StaticService.queueSize = int(value.intVal)
  of "timeoutMs":
    if StaticService.serviceType notin {ThreadService, ChannelService}:
      error("Service field `timeoutMs` is only supported by `ThreadService`", value)
    StaticService.timeoutMs = int(value.intVal)
  of "socketPath":
    if StaticService.serviceType notin {UnixService}:
      error("Service field `socketPath` is only supported by `UnixService`", value)
    value.expectKind(nnkStrLit)
    StaticService.socketPath = value.strVal
  of "socketMode":
    if StaticService.serviceType notin {UnixService}:
      error("Service field `socketMode` is only supported by `UnixService`", value)
    StaticService.socketMode = int(value.intVal)
  of "poolSize":
    if StaticService.serviceType notin {ThreadPoolService}:
      error("Service field `poolSize` is only supported by `ThreadPoolService`", value)
    StaticService.poolSize = int(value.intVal)
  else:
    error("Unknown service field `" & fieldName & "` for " &
      $StaticService.serviceType & " service `" & StaticService.name & "`", value)

const
  ServiceManagerThreadServices* = CacheTable"ServiceManagerThreadServices"
  ServiceManagerThreadServicesClients* = CacheTable"ServiceManagerThreadServicesClients"

var
  rng {.compileTime.} = initRand(0x1337DEADBEEF)
  serviceManagerOnce = once.createOnce()

#
# Utilities
#
template initRouter*: untyped =
  macro loadQueuedRoutes: untyped =
    result = newStmtList()
    add result,
      newVarStmt(routerInstance, newCall(ident"newHttpRouter")),
      newVarStmt(index,newCall(ident"HttpRoutes"))
    for k, routeHandle in queuedRoutes:
      let pathKey = newLit(routeHandle[2].strVal)
      let pathMethod = replace(routeHandle[3].strVal, "Http").toUpperAscii
      var routeMetaObj = 
        nnkObjConstr.newTree(
          ident"HttpRouteMeta",
          nnkExprColonExpr.newTree(
            nnkAccQuoted.newTree(ident"method"),
            routeHandle[3]
          ),
          nnkExprColonExpr.newTree(
            ident"path",
            routeHandle[2]
          ),
          nnkExprColonExpr.newTree(
            ident"regex",
            routeHandle[1]
          ),
        )
      if not routeHandle[4].isNil:
        add routeMetaObj,
          nnkExprColonExpr.newTree(
            ident"description",
            routeHandle[4]
          )
      add result,
        # register meta data for each route
        newIfStmt(
          (
            nnkPrefix.newTree(
              ident"not",
              newCall(ident"hasKey", index, pathKey)
            ),
            nnkStmtList.newTree(
              newAssignment(
                nnkBracketExpr.newTree(index, pathKey),
                newCall(ident"HttpRouteVerbs")
              )
            )
          )
        ),
        newAssignment(
          nnkBracketExpr.newTree(
            nnkBracketExpr.newTree(index, pathKey),
            newLit(pathMethod)
          ),
          routeMetaObj
        )
      add result,
        # register route
        routeHandle[5],
        newCall(
          ident"registerRoute",
          routerInstance,
          nnkTupleConstr.newTree(
            routeHandle[1],
            routeHandle[2]
          ),
          routeHandle[3],
          routeHandle[0]
        )
      
    # resets the `queuedRoutes` table to avoid overlapping
    # with the next service provider's routes
    queuedRoutes = CacheTable("resetCacheTable" & $(rng.rand(10)))
  loadQueuedRoutes()

template initChannelRouter* =
  ## Initialize the router for the channel-based service.
  ## The API provided by the channel-based service is similar to
  ## the one provided by the web service. The only difference is
  ## that the channel-based service does not require a web server.
  macro loadQueuedRoutes: untyped =
    result = newStmtList()
    add result,
      newVarStmt(routerInstance, newCall(ident"newHttpRouter")),
      newVarStmt(index,newCall(ident"HttpRoutes"))
    for k, routeHandle in queuedRoutes:
      let pathKey = newLit(routeHandle[2].strVal)
      let pathMethod = replace(routeHandle[3].strVal, "Http").toUpperAscii
  loadQueuedRoutes()

macro initService*(serviceIdentifier, serviceConfig: untyped) =
  ## Create a new Supranim Service. Supported service types:
  ##
  ## `Singleton` services live in the main app as a `pkg/threading/once`
  ## singleton. Use `state do:` for the type and `api do:` for accessors
  ## (`backend`/`client` are accepted as aliases). Top-level fields:
  ## `description`, `author`, `version`, `autoStart`.
  ##
  ## `ThreadService` services are job-threads: they run user code for as
  ## long as they want and talk to the main app through the
  ## application-owned `Chan[ServiceMsg]`. Use `shared do:` for types
  ## visible on both sides, `thread do:` for the worker body (the channel
  ## is available via `get<Name>Channel()`), and `api do:` for the
  ## main-thread handles. Top-level fields: `queueSize`, `timeoutMs`,
  ## `autoStart`. Cannot be built as a standalone binary.
  ##
  ## `ThreadPoolService` services wrap powpow's `ThreadPool`: N anonymous
  ## workers run submitted jobs, callbacks fire serialized on the pool
  ## dispatch thread. Use `shared do:` for job/result types and `api do:`
  ## for submit handles (`get<Name>Pool()` exposes the raw pool).
  ## Top-level fields: `poolSize`, `autoStart`. Cannot be built standalone.
  ##
  ## `WebService` services are HTTP microservices over TCP/IP with a
  ## dual mode: embedded in an application thread, or compiled as a
  ## standalone binary (`isMainModule`). Top-level fields: `host`,
  ## `port`, `threads`, `autoStart`. With a `ws do:` block (exclusive
  ## with `routes do:`) it runs a standalone WebSocket server instead,
  ## in thread or standalone mode alike.
  ##
  ## `UnixService` services behave like `WebService` but listen on a
  ## Unix domain socket (`socketPath`, `socketMode`). Great for fast
  ## local IPC.
  ##
  ## https://dev.to/vearutop/using-nginx-as-a-proxy-to-multiple-unix-sockets-3c7a
  let initInfo: (string, int, int) = instantiationInfo(fullPaths = true)
  var
    clientSideRoutePaths: seq[(string, HttpMethod, Autolinked)]
    serviceNameStr: string
    serviceType: ServiceType
    serviceNameSingletonOf: string
  if serviceIdentifier[1].kind == nnkBracketExpr:
    serviceNameStr = serviceIdentifier[0].strVal
    serviceNameSingletonOf = serviceIdentifier[1][1].strVal
    serviceType = parseEnum[ServiceType](serviceIdentifier[1][0].strVal)
  else:
    serviceNameStr = serviceIdentifier[0].strVal
    serviceType = parseEnum[ServiceType](serviceIdentifier[1].strVal)
  StaticService = 
    ServiceProvider(
      name: serviceNameStr,
      serviceType: serviceType,
      autoStart: true
    )
  result = newStmtList()
  var backendNode, clientNode, routesNode, wsNode, sharedNode, threadNode: NimNode

  for attr in serviceConfig:
    case attr.kind
    of nnkAsgn:
      # top-level `field = value` configuration, validated per service type
      setServiceField(attr[0].strVal, attr[1])
    of nnkCall:
      if attr[0].eqIdent"config":
        # service may provide additional configuration
        echo attr[1].repr
      elif attr[0].eqIdent"backend" or attr[0].eqIdent"state":
        # `state do:` is the Singleton-friendly alias of `backend do:`
        backendNode = attr[1]
      elif attr[0].eqIdent"client" or attr[0].eqIdent"api":
        # `api do:` is the Singleton-friendly alias of `client do:`
        clientNode = attr[1]
      elif attr[0].eqIdent"shared":
        # `ThreadService` types shared between app and worker thread
        sharedNode = attr[1]
      elif attr[0].eqIdent"thread":
        # `ThreadService` worker body (runs inside the thread proc)
        threadNode = attr[1]
      elif attr[0].eqIdent"ws":
        # `WebService` standalone WebSocket server body, configures `wss`
        wsNode = attr[1]
      elif attr[0].eqIdent"routes":
        # Collect service routes
        routesNode = attr
    else: discard

  var
    serverHandle = newStmtList()
    clientHandle = newStmtList()
    serviceThreads = newEmptyNode()
  
  if backendNode.isNil:
    backendNode = newStmtList()

  let serviceDescription = newLit(StaticService.description)
  if StaticService.serviceType in {WebService, UnixService}:
    # Handle definition of HTTP-based web services
    serviceThreads = newLit(StaticService.threads)
    add serverHandle, quote do:
      # Required modules for Service Provider
      import std/[asyncdispatch, httpcore, options,
              critbits, json, strutils, sequtils, uri]
      
      import pkg/openparser/json
      
      import pkg/supranim/network/webserver
      import pkg/supranim/network/websocket
      import pkg/supranim/core/[request, router, response]
      
      from std/net import Port

      type
        ErrorResponse* {.inject.} = object
          ## A predefined HTTP Error Response Object
          ## containing standard fields.
          code: HttpCode
            ## Http Status Code
          message: string
            ## HTTP Error Response Object

      proc newErrorResponse(code: range[100..599]; message: string): ErrorResponse =
        ErrorResponse(code: HttpCode(code), message: message)

      proc notFound(errorCode: uint, args: varargs[string]): JsonNode =
        %*{"code": 404, "error_code": errorCode, "args": args.toSeq}

      proc newError(httpCode: HttpCode, errorCode: uint, args: varargs[string]): JsonNode =
        %*{"code": $httpCode, "error_code": errorCode, "args": args.toSeq}

      #
      # Request Utils
      #
      proc setParams*(req: var Request, params: sink Table[string, string]) =
        ## Sets the route parameters in `Request`
        req.routeParams = params

      proc params*(req: Request): lent Table[string, string] =
        ## Returns the route parameters from `Request`
        req.routeParams

      proc getFields(req: Request): seq[(string, string)] =
        ## Decodes `Request` body and returns as a sequence of tuples
        toSeq(req.body.get().decodeQuery)

      proc getFieldsJson(req: Request): JsonNode =
        ## Decodes `Request` body and returns a JsonNode
        try:
          result = fromJson(req.body.get(), JsonNode)
        except OpenParserJsonError as e:
          echo e.msg

      proc getFieldsTable(req: Request, fromJson: bool = false): Table[string, string] =
        ## Decodes `Request` body to `Table[string, string]`
        ## Optionally set `fromJson` to true if data is sent as JSON
        if fromJson:
          let jsonData = req.getFieldsJson()
          if likely(jsonData != nil):
            for k, v in jsonData:
              result[k] = v.getStr
        else:
          for x in req.body.get().decodeQuery:
            result[x[0]] = x[1]

      proc getFieldsObject[T](req: Request, t: typedesc[T]): Option[T] =
        ## Decodes `Request` body from stringified JSON to Nim object
        try:
          result = some(fromJson(req.body.get(), t))
        except OpenParserJsonError:
          result = none(t)

      proc toString(headers: HttpHeaders): string =
        ## Convert `headers` to string
        if not headers.isNil:
          var str: seq[string]
          for h in headers.pairs():
            str.add(h.key & ":" & indent(h.value, 1))
          result &= str.join("\n")

      #
      # Http response handlers
      #
      template respond(req: var Request; code: range[100..599]; body: untyped) =
        ## Send a HTTP response
        var headers = newHttpHeaders()
        headers["Content-Type"] = "application/json"
        req.send(HttpCode(code), toJson(body), headers)
        return

      template respond(req: var Request; code: range[100..599]) =
        ## Send a HTTP response
        var headers = newHttpHeaders()
        headers["Content-Type"] = "application/json"
        req.send(HttpCode(code), "", headers)
        return

      template respond(req: var Request; body: untyped) =
        ## Send a HTTP response using default `HttpCode(200)`
        var headers = newHttpHeaders()
        headers["Content-Type"] = "application/json"
        req.send(HttpCode(200), toJson(body), headers)
        return

      template error(req: var Request; code: range[400..599]; body: untyped) =
        ## Sends a HTTP Error response using a HttpCode range from `4xx` to `5xx`
        # todo prevent body for certain responses based on given code.
        var headers = newHttpHeaders()
        headers["Content-Type"] = "application/json"
        req.send(HttpCode(code), toJson(body), headers)
        return

  elif StaticService.serviceType == Global:
    add serverHandle, quote do:
      when isMainModule:
        error("Supranim Service Manager - Singleton Services cannot be built as standalone services")
  
  elif StaticService.serviceType == Singleton:
    # Handle definition of a Singleton service.
    add serverHandle, quote do:
      when isMainModule:
        error("Supranim Service Manager - Singleton Services cannot be built as standalone services")

    let
      singletonIdent = ident(StaticService.name)
      singletonOfIdent = ident(serviceNameSingletonOf)
      procInstanceIdent = ident("get" & StaticService.name & "Instance")
    add backendNode, quote do:
      type
        OnInitSingletonCallback* = proc(instance: ptr `singletonIdent.`) {.gcsafe.}
      var o = createOnce()
      var instance: ptr `singletonIdent.`
      proc `procInstanceIdent`*(onceCb: OnInitSingletonCallback = nil,
                        initShared: static bool = true): ptr `singletonIdent.` =
        ## Retrieve the singleton instance of the service
        once(o): # Initialize the singleton instance
          instance = 
            when initShared == true:
              createShared(`singletonIdent.`)
            else:
              createSharedU(`singletonIdent.`)
          # Call the user-defined initialization callback
          if onceCb != nil: onceCb(instance)
        result = instance # return the singleton instance

  elif StaticService.serviceType in {ThreadService, ChannelService}:
    # Handle definition of a ThreadService job-thread.
    # The worker runs user code for as long as it wants and talks
    # to the main application through the application-owned
    # `Chan[ServiceMsg]` (see `core/application`). There is no
    # HTTP server here, use `WebService` for thread-based web services.
    add serverHandle, quote do:
      when isMainModule:
        error("Supranim Service Manager - Thread Services cannot be built as standalone services")

    if not routesNode.isNil:
      error("Supranim Service Manager - Thread Service `" & StaticService.name &
        "` cannot define `routes`. Use a `WebService` for thread-based web services")
    if not wsNode.isNil:
      error("Supranim Service Manager - Thread Service `" & StaticService.name &
        "` cannot define a `ws` block. Use a `WebService` for websocket servers")
    if threadNode.isNil:
      error("Supranim Service Manager - Thread Service `" & StaticService.name &
        "` requires a `thread do:` block with the worker body")

    let
      chanIdent = ident(StaticService.name & "ThreadChan")
      threadHandleIdent = ident(StaticService.name & "ThreadHandle")
      threadRunningIdent = ident(StaticService.name & "ThreadRunning")
      threadProcIdent = ident("run" & StaticService.name & "Thread")
      channelProcIdent = ident("get" & StaticService.name & "Channel")
      startProcIdent = ident("start" & StaticService.name & "Service")
      stopProcIdent = ident("stop" & StaticService.name & "Service")
      serviceNameLit = newLit(StaticService.name)
      queueSizeLit = newLit(StaticService.queueSize)

    if not sharedNode.isNil:
      add serverHandle, sharedNode
    if not backendNode.isNil:
      add serverHandle, backendNode

    add serverHandle, quote do:
      var `chanIdent`: Chan[ServiceMsg]
      var `threadHandleIdent`: Thread[void]
      var `threadRunningIdent`: bool

      proc `channelProcIdent`*(): ptr Chan[ServiceMsg] =
        ## Return the application-owned channel of this service.
        ## The worker thread uses it to receive jobs; the main
        ## application uses it (or `sendServiceMsg`) to send them.
        addr `chanIdent`

      proc `threadProcIdent`() {.thread.} =
        {.gcsafe.}:
          `threadNode`

      proc `startProcIdent`*(app: Application,
          queueSize: int = `queueSizeLit`): bool =
        ## Create the application-owned channel, register it on `app`
        ## and spawn the worker thread. Returns `false` when already running.
        if `threadRunningIdent`: return false
        `chanIdent` = newChan[ServiceMsg](queueSize)
        app.registerServiceChan(`serviceNameLit`, `chanIdent`)
        createThread(`threadHandleIdent`, `threadProcIdent`)
        `threadRunningIdent` = true
        true

      proc `stopProcIdent`*(app: Application): bool =
        ## Ask the worker to exit (poison pill) and join the thread.
        ## The worker must exit its loop on `isServiceStop(msg)`.
        ## Returns `false` when not running.
        if not `threadRunningIdent`: return false
        `chanIdent`.send(ServiceMsg(action: ServiceStopAction, payload: ""))
        joinThread(`threadHandleIdent`)
        `threadRunningIdent` = false
        true

    if not clientNode.isNil:
      add serverHandle, clientNode

    if StaticService.autoStart:
      # Start the worker thread at program startup, same as before
      add serverHandle, quote do:
        discard `startProcIdent`(appInstance())

  elif StaticService.serviceType == ThreadPoolService:
    # Handle definition of a ThreadPoolService job-pool.
    # Backed by `supranim_tasks` `TaskManager`: N anonymous workers
    # run submitted jobs, callbacks fire serialized on the pool
    # dispatch thread, and a private scheduler thread drives delayed,
    # repeating and wall-clock tasks. Unlike `ThreadService` there
    # is no worker body and no channel plumbing of its own.
    add serverHandle, quote do:
      import supranim_tasks
      import pkg/powpow/threadpool
      when isMainModule:
        error("Supranim Service Manager - Thread Pool Services cannot be built as standalone services")

    if not routesNode.isNil:
      error("Supranim Service Manager - Thread Pool Service `" & StaticService.name &
        "` cannot define `routes`. Submit jobs via the `api` handles instead")
    if not wsNode.isNil:
      error("Supranim Service Manager - Thread Pool Service `" & StaticService.name &
        "` cannot define a `ws` block. Submit jobs via the `api` handles instead")
    if not threadNode.isNil:
      error("Supranim Service Manager - Thread Pool Service `" & StaticService.name &
        "` cannot define a `thread do:` block. There is no worker body, submit jobs via the `api` handles instead")

    let
      poolIdent = ident(StaticService.name & "Pool")
      poolRunningIdent = ident(StaticService.name & "PoolRunning")
      poolProcIdent = ident("get" & StaticService.name & "Pool")
      rawPoolProcIdent = ident("get" & StaticService.name & "RawPool")
      runningProcIdent = ident("is" & StaticService.name & "ServiceRunning")
      haltProcIdent = ident("halt" & StaticService.name & "Service")
      startProcIdent = ident("start" & StaticService.name & "Service")
      stopProcIdent = ident("stop" & StaticService.name & "Service")
      poolSizeLit = newLit(StaticService.poolSize)

    if not sharedNode.isNil:
      add serverHandle, sharedNode
    if not backendNode.isNil:
      add serverHandle, backendNode

    add serverHandle, quote do:
      var `poolIdent`: TaskManager
      var `poolRunningIdent`: bool

      proc `poolProcIdent`*(): TaskManager =
        ## Return the task manager. Submitted jobs run on worker
        ## threads; `cb`/`onError` callbacks run serialized on the
        ## pool dispatch thread, never on the main thread: lock
        ## shared state and never touch a `Request` from a callback.
        ## Delayed, repeating and wall-clock tasks run on the same
        ## manager (`submitDelayed`, `submitRepeating`, `scheduleAt`,
        ## `scheduleDaily`, `scheduleWeekly`). Job closures must not
        ## capture `ref` objects across threads (values, strings,
        ## locks and raw pointers only).
        `poolIdent`

      proc `rawPoolProcIdent`*(): ThreadPool =
        ## Escape hatch: the underlying powpow pool, for direct
        ## `submitWork` access. Prefer the `TaskManager` procs
        ## (`submit` returns a cancellable `JobId`).
        `poolIdent`.rawPool()

      proc `runningProcIdent`*(): bool =
        ## True while the pool is up (`start*Service` ran and
        ## `stop*Service`/`halt*Service` has not finished).
        `poolIdent`.isRunning()

      proc `haltProcIdent`*(app: Application, delayMs: int): bool {.discardable.} =
        ## Stop the pool after `delayMs` milliseconds. Unlike
        ## `stop*Service` (which joins pool threads) this only
        ## enqueues the shutdown, so it is safe to call from inside
        ## a pool job or callback. Returns `false` when already
        ## stopping or closed.
        `poolIdent`.halt(delayMs)

      proc `startProcIdent`*(app: Application,
          poolSize: int = `poolSizeLit`): bool =
        ## Create the task manager (`newTaskManager`: pool workers
        ## plus the scheduler thread) and mark it running.
        ## Returns `false` when already running.
        if `poolRunningIdent`: return false
        `poolIdent` = newTaskManager(poolSize)
        `poolRunningIdent` = true
        true

      proc `stopProcIdent`*(app: Application): bool =
        ## Gracefully stop the manager (`close`: drains queued jobs
        ## and delivers pending callbacks, drops timers) and mark it
        ## stopped. Blocks until pool and scheduler threads join, so
        ## it must run outside pool jobs/callbacks — from inside,
        ## use `halt*Service` instead.
        ## Returns `false` when not running.
        if not `poolRunningIdent`: return false
        `poolIdent`.close()
        `poolRunningIdent` = false
        true

    if not clientNode.isNil:
      add serverHandle, clientNode

    if StaticService.autoStart:
      # Start the pool at program startup, same as other services
      add serverHandle, quote do:
        discard `startProcIdent`(appInstance())

  # if backendNode != nil:
    # add serverHandle, backendNode

  if not routesNode.isNil:
    # Parse service routes
    queuedRoutes = CacheTable("ServiceRoutes:" & StaticService.name)
    for httpRoute in routesNode[1]:
      expectKind(httpRoute, nnkCommand)
      let httpRouteMethod = parseEnum[HttpMethod](toUpperAscii(httpRoute[0].strVal))
      if httpRoute[1].kind == nnkStrLit:
        # auto generate names of the client side functions
        # based on the route path and http method
        let httpRouteAutolink = autolinkController(httpRoute[1].strVal, httpRouteMethod)
        add clientSideRoutePaths, (httpRouteAutolink.handleName, httpRouteMethod, httpRouteAutolink)
      elif httpRoute[1].kind == nnkInfix:
        # extract the specified ident name 
        # for generating the client-side functions
        # then replace the infix node with the nnkStrLit (route path)
        if httpRoute[1][0].strVal == "=>":
          if httpRoute[1][2].kind == nnkBracketExpr:
            let httpRouteAutolink = autolinkController(httpRoute[1][2][0].strVal, httpRouteMethod)
            add clientSideRoutePaths, (httpRouteAutolink.handleName, httpRouteMethod, httpRouteAutolink)
          else:
            let httpRouteAutolink = autolinkController(httpRoute[1][1].strVal, httpRouteMethod)
            add clientSideRoutePaths, (httpRouteAutolink.handleName, httpRouteMethod, httpRouteAutolink)
          httpRoute[1] = httpRoute[1][1]
      else: discard # todo error?
    
    add backendNode, routesNode
    add backendNode, newCall(ident"initRouter")
    
  let serviceName = newLit(StaticService.name)

  if StaticService.serviceType in {WebService, UnixService}:
    # Shared HTTP plumbing (index + request handler) for
    # TCP (`WebService`) and Unix-socket (`UnixService`) services

    let httpServiceIndex = genSym(nskVar, "httpServiceIndex")
    add backendNode, quote do:
      let `httpServiceIndex`* = HttpServiceIndex(
        description: `serviceDescription.`,
        routes:`index.`
      )

      when defined release:
        # marks the service as a release build
        # this is used to add a note to the service index
        httpServiceIndex.release_mode = true

      #
      # HTTP Request Handler
      #
      template onRequestHandle =
        proc onRequest(req: var Request) =
          ## Handles incoming HTTP requests
          {.gcsafe.}:
            let path = req.getUriPath()
            var res = Response(headers: newHttpHeaders())
            case path:
              of "/":
                # The `/` root path always returns
                # a JSON index of all available routes
                respond(req, httpServiceIndex)
              else:
                # Handle other routes
                let reqPath = req.getUriPath()
                let reqMethod = req.getHttpMethod()
                let runtimeCheck = checkExists(`routerInstance.`, reqPath, reqMethod)
                case runtimeCheck.exists
                  of true:
                    req.setParams(runtimeCheck.params)
                    let middlewareStatus: HttpCode =
                      runtimeCheck.route.resolveMiddleware(req, res)
                    case middlewareStatus
                      of Http301, Http302, Http303:
                        req.resp(middlewareStatus, "", res.getHeaders())
                      of Http204:
                        # once middleware passed we can
                        # execute controller's handle
                        runtimeCheck.route.callback(req, res)
                        req.resp(res.getCode, res.getBody, res.getHeaders)
                      else:
                        discard # todo
                  else: req.respond(501, newErrorResponse(501, "Not implemented"))
    
    # if StaticService.serviceType == ThreadService:
    #   if StaticService.autoStart:
    #     # When the service is set to `autoStart`
    #     # start it in its own thread
    if not wsNode.isNil and not routesNode.isNil:
      error("Supranim Service Manager - Web Service `" & StaticService.name &
        "` cannot combine `routes do:` with a `ws do:` block. " &
        "Use `routes` (with the `ws` verb) for HTTP-upgrade sockets, " &
        "or a lone `ws do:` block for a standalone WebSocket server")
    if StaticService.serviceType == UnixService and not wsNode.isNil:
      error("Supranim Service Manager - `UnixService` `" & StaticService.name &
        "` cannot define a `ws` block. WebSocket servers listen on TCP, use `WebService`")
    if StaticService.serviceType == UnixService and StaticService.socketPath.len == 0:
      error("Supranim Service Manager - `UnixService` `" & StaticService.name &
        "` requires a `socketPath = \"...\"` field")

    let
      svcHost = newLit(StaticService.host)
      svcStandalonePort = newLit(if StaticService.port != 0: StaticService.port else: 3000)
      svcThreadPort = newLit(if StaticService.port != 0: StaticService.port else: 9000)
      svcThreads = newLit(StaticService.threads)
      svcSocketPath = newLit(StaticService.socketPath)
      svcSocketMode = newLit(StaticService.socketMode)
      isUnixSvc = newLit(StaticService.serviceType == UnixService)
      isWsSvc = newLit(not wsNode.isNil)
      isAutoStartSvc = newLit(StaticService.autoStart)

    if not wsNode.isNil:
      # Standalone WebSocket server (powpow `WsServer`) on its own
      # port. Works both embedded in an application thread and
      # compiled as a standalone binary. `wsNode` configures `wss`.
      let
        wsBlock = wsNode
        wsBlockThread = wsNode.copy()
      add backendNode, quote do:
        when isMainModule:
          # Boot as a standalone websocket server
          var p = initOptParser(commandLineParams())
          p.next() # skip the binary name
          var wsHost = `svcHost`
          var wsPort = `svcStandalonePort`
          for kind, key, val in p.getOpt():
            case kind
            of cmdShortOption, cmdLongOption:
              case key
              of "p", "port": wsPort = parseInt(val)
              of "h", "host": wsHost = val
              else: discard
            else: discard

          displayInfo("Starting " & `serviceName` & " websocket service")
          displayInfo("Available at ws://" & wsHost & ":" & $wsPort)

          var wss = newWsServer()
          `wsBlock`
          wss.listen(wsHost, wsPort)
          wss.start()
        else:
          if `isAutoStartSvc`:
            block:
              var thrService: Thread[void]
              proc runWsService {.thread.} =
                # the thread proc running the websocket server
                {.gcsafe.}:
                  var wss = newWsServer()
                  `wsBlockThread`
                  wss.listen(`svcHost`, `svcThreadPort`)
              createThread(thrService, runWsService)
              display(
                span((`serviceName` & " Service").indent(4)),
                green("[ws]"),
              )
    else:
      add backendNode, quote do:
        when isMainModule:
          # Boot the service provider as a
          # standalone service using the built-in web server
          var p = initOptParser(commandLineParams())
          p.next() # skip the binary name
          var host = `svcHost`
          var port = Port(`svcStandalonePort`)
          var threads = `svcThreads`
          for kind, key, val in p.getOpt():
            case kind
            of cmdShortOption, cmdLongOption:
              case key
              of "p", "port": port = Port(parseInt(val))
              of "h", "host": host = val
              of "t", "threads": threads = parseInt(val)
              else: discard
            else: discard

          when `isUnixSvc`:
            displayInfo("Starting the pluggable service provider")
            displayInfo("Available at unix://" & `svcSocketPath`)
            onRequestHandle()
            webserver.runUnixServer(onRequest, nil, `svcSocketPath`, `svcSocketMode`)
          else:
            displayInfo("Starting the pluggable service provider")
            displayInfo("Available at http://" & host & ":" & $(port))

            # Start the web server
            onRequestHandle()
            if threads > 1:
              webserver.runServer(onRequest, nil, port, threads, host)
            else:
              webserver.runServer(onRequest, nil, port, host)
        else:
          # Embedded in the main application: serve from its own thread
          if `isAutoStartSvc`:
            block:
              var thrService: Thread[void]
              onRequestHandle()
              proc runThreadService {.thread.} =
                # the thread proc handling the service
                {.gcsafe.}:
                  when `isUnixSvc`:
                    webserver.runUnixServer(onRequest, nil,
                      `svcSocketPath`, `svcSocketMode`)
                  elif `svcThreads` > 1:
                    webserver.runServer(onRequest, nil,
                      Port(`svcThreadPort`), `svcThreads`, `svcHost`)
                  else:
                    webserver.runServer(onRequest, nil,
                      Port(`svcThreadPort`), `svcHost`)

              # Create a thread for the service
              createThread(thrService, runThreadService)

              # Log service start info
              display(
                span((`serviceName.` & " Service").indent(4)),
                green("[thread]"),
              )
            

    #
    # Client-side API
    #
    var httpClientId = ident(StaticService.name & "Client")
    add clientHandle, quote do:
      import std/[json, asyncdispatch]
      import pkg/jsony
      import pkg/supranim/support/httpclient
      import pkg/supranim/network/webserver
      # powpow's HTTP client handles HTTP operations over Unix Sockets

    add clientHandle, quote do:
      type
        ServiceProviderClient* {.inject.} = object of RootObj
          base: AsyncHttpClient
        ApiServiceProviderResponse*[T] {.inject.} = object
        SessionClient* {.inject.} = object of ServiceProviderClient
        # todo finish generate client-side API based on macros

    # Typed client for this service. One async proc per route,
    # using the right HTTP method, path params and an optional
    # `unixSocket` (used by `UnixService`).
    add clientHandle, quote do:
      type
        `httpClientId`* = object of RootObj
          baseUrl*: string
          unixSocket*: string
    let
      clientTypeIdent = ident(StaticService.name & "Client")
      newClientName = ident("new" & StaticService.name & "Client")
    add clientHandle, newProc(
      name = nnkPostFix.newTree(ident"*", newClientName),
      params = [
        clientTypeIdent,
        nnkIdentDefs.newTree(ident"baseUrl", ident"string", newEmptyNode()),
        nnkIdentDefs.newTree(ident"unixSocket", ident"string", newLit(""))
      ],
      body = newStmtList(
        newAssignment(ident"result",
          nnkObjConstr.newTree(
            ident(StaticService.name & "Client"),
            nnkExprColonExpr.newTree(ident"baseUrl", ident"baseUrl"),
            nnkExprColonExpr.newTree(ident"unixSocket", ident"unixSocket")))
      )
    )

    for fnEndpoint in clientSideRoutePaths:
      let
        routeMethodIdent = ident($fnEndpoint[1])
        endpointIdent = nnkPostFix.newTree(ident"*", ident(fnEndpoint[0]))
        bodyParamIdent = ident"body"
        bodyUseIdent = ident"body"
      var procParams = @[
        nnkBracketExpr.newTree(ident"Future", ident"HttpClientResponse"),
        nnkIdentDefs.newTree(ident"c", httpClientId, newEmptyNode())
      ]
      if fnEndpoint[2].params.isSome():
        for p in fnEndpoint[2].params.get():
          procParams.add(nnkIdentDefs.newTree(ident(p[0]), ident"string", newEmptyNode()))
      procParams.add(nnkIdentDefs.newTree(bodyParamIdent, ident"string", newLit("")))
      let
        baseUrlExpr = nnkDotExpr.newTree(ident"c", ident"baseUrl")
        urlExpr = clientUrlExpr(baseUrlExpr, fnEndpoint[2].path)
        unixSocketExpr = nnkDotExpr.newTree(ident"c", ident"unixSocket")
      var clientProcBody = quote do:
        var httpc = newAsyncHttpClient()
        defer: httpc.close()
        let noHeaders: seq[(string, string)] = @[]
        let url = `urlExpr`
        return await httpc.request(`routeMethodIdent`, url, `bodyUseIdent`,
          noHeaders, `unixSocketExpr`)
      add clientHandle, newProc(
        name = endpointIdent,
        params = procParams,
        pragmas = nnkPragma.newTree(ident"async"),
        body = clientProcBody
      )

  if not clientNode.isNil:
    # In case we have any other client nodes
    add clientHandle, clientNode

  case StaticService.serviceType
  of ThreadService, ChannelService, ThreadPoolService:
      # Job-thread services live in the application process.
      # `serverHandle` already holds the shared types, the channel
      # plumbing with `start*Service` / `stop*Service`, the worker
      # body and the `api` handles (`ThreadPoolService` holds the
      # pool with `start*Service` / `stop*Service` instead of a
      # worker body). Cannot be built standalone
      # (enforced above via `when isMainModule: error`).
      add result, serverHandle
  of Singleton, Global:
    # Singleton services are built as part of the main app
    # and are not available as standalone services.
    #
    # Once initialized, the service is available
    # as a singleton and can be shared between multiple threads.
    #
    # This feature is powered by
    # `pkg/threading/once` module.
    add serverHandle, backendNode
    add serverHandle, clientHandle
    add result, serverHandle
  of WebService, UnixService:
    # Dual mode: the server definition is always emitted.
    # The inner `when isMainModule` in `backendNode` boots a
    # standalone binary, otherwise an application thread serves it.
    # `clientHandle` holds the typed client for the main app
    # (it also compiles standalone, where it is simply unused).
    add serverHandle, backendNode
    add serverHandle, clientHandle
    add result, serverHandle
  when defined supraDebugServiceProviderCode:
    echo result.repr

macro extractThreadServicesBackend* =
  ## Extracts the generated client-side API
  ## for the `ThreadService` and `ChannelService`
  ## and saves it in a runtime folder
  ## ({app}/.runtime/). The generated code is then
  ## available to the main application via `import supranim/runtime`
  result = newStmtList()
  for id, handle in ServiceManagerThreadServices:
    echo handle.repr
    # add result, handle
    # let fpath = cachePath / "f" & id & ".nim"
    # writeFile(fpath, handle.repr)
    # let runtimeImport = newLit(fpath)
    # add result, quote do:
    # import `runtimeImport.`

macro extractThreadServicesClient* =
  ## Extracts the generated client-side API
  ## for the `ThreadService` and `ChannelService`
  ## and saves it in a runtime folder
  ## ({app}/.runtime/). The generated code is then
  ## available to the main application via `import supranim/runtime`
  result = newStmtList()
  for id, handle in ServiceManagerThreadServicesClients:
    let fpath = cachePath / "f" & id & ".nim"
    writeFile(fpath, handle.repr)
    let runtimeImport = newLit(fpath)
    add result, quote do:
      import `runtimeImport.`
