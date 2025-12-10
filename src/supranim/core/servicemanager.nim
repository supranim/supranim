#
# Supranim - A high-performance MVC web framework for Nim,
# designed to simplify web application and REST API development.
# 
#   (c) 2025 MIT License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#

import std/[os, macros, macrocache, tables, sequtils,
          critbits, strutils, random, parseopt, options]

import pkg/checksums/md5
import pkg/threading/once
import pkg/kapsis/cli

import pkg/supranim/application
import pkg/supranim/[router, controller]
import pkg/supranim/core/paths
import pkg/supranim/http/autolink

from std/net import Port, `$`
from std/httpcore import HttpCode, HttpMethod

export macros, macrocache, tables, once, options, controller

type
  ServiceType* = enum
    ## Defines Supranim Service types
    Global = "Global"
      ## Defines a Global service as part of the main application
    Singleton = "Singleton"
      ## Defines a Singleton service as part of the main application
    ChannelService = "Channel"
      ## Thread-based Service enabling inter thread communications 
    # UnixService = "UnixService"
    WebService = "WebService"
      ## REST API Service Provider that connects over TCP/IP
    ThreadService = "ThreadService"
      ## Defines thread-based `WebService` part of the main application
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
    serviceType: ServiceType
    name*, description*, author*, version*: string
    threads: uint = 0 # by default all services are single-threaded
    autoStart: bool
      # Whether the service should auto start on application boot
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

template initService*(id, config: untyped) =
  ## Create a new Supranim Service. Supported service types:
  ## 
  ## `Singleton` Services are built within the main app providing
  ## a singleton pattern based on `pkg/threading/once`.
  ## 
  ## `ChannelService` Services are thread-based services
  ## that can be used for inter-thread communication
  ## 
  ## `UnixService` and `WebService` Services are REST API microservices
  ## wrapped by the built-in web server based on `pkg/httbeast`
  ##
  ## https://dev.to/vearutop/using-nginx-as-a-proxy-to-multiple-unix-sockets-3c7a
  macro createService(serviceIdentifier, serviceConfig) = 
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
    var backendNode, clientNode, routesNode: NimNode
    for attr in serviceConfig:
      case attr.kind
      of nnkAsgn:
          if attr[0].eqIdent"autoStart":
            StaticService.autoStart = attr[1].eqIdent"true"
      #   if attr[0].eqIdent"description":
      #     StaticService.description = attr[1].strVal
      #   elif attr[0].eqIdent"threads":
      #     if attr[1].intVal > 1:
      #       StaticService.threads = attr[1].intVal.uint
      #     else: discard # use main thread as default 
      of nnkCall:
        if attr[0].eqIdent"config":
          # service may provide additional configuration
          echo attr[1].repr
        elif attr[0].eqIdent"backend":
          backendNode = attr[1]
        elif attr[0].eqIdent"client":
          clientNode = attr[1]
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
    if StaticService.serviceType in {WebService, ThreadService, ChannelService}:
      # Handle definition of HTTP-based web services
      serviceThreads = newLit(StaticService.threads)
      add serverHandle, quote do:
        # Required modules for Service Provider
        import std/[asyncdispatch, httpcore, options,
                critbits, json, strutils, sequtils, uri]
        import pkg/supranim/http/[webserver, request, router, response]
        import pkg/jsony
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
        proc getFields(req: Request): seq[(string, string)] =
          ## Decodes `Request` body and returns as a sequence of tuples
          toSeq(req.body.get().decodeQuery)

        proc getFieldsJson(req: Request): JsonNode =
          ## Decodes `Request` body and returns a JsonNode
          try:
            result = fromJson(req.body.get(), JsonNode)
          except jsony.JsonError:
            discard

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
          except jsony.JsonError:
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
        
        proc `procInstanceIdent.`*(onceCb: OnInitSingletonCallback = nil): ptr `singletonIdent.` =
          once(o):
            # Initialize the singleton instance
            instance = createShared(`singletonIdent.`)
            # Call the user-defined initialization callback
            if onceCb != nil: onceCb(instance)
          result = instance

    # if backendNode != nil:
      # add serverHandle, backendNode

    if not routesNode.isNil:
      # Parse service routes
      queuedRoutes = CacheTable(StaticService.name & $(rng.rand(10)))
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
      
    let threadService = genSym(nskVar, "serviceType")
    let serviceName = newLit(StaticService.name)

    if StaticService.serviceType in {WebService, ThreadService}:
      add backendNode,
        newVarStmt(threadService,
          newLit(StaticService.serviceType in {ThreadService, ChannelService}))

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
      var isThreadService = newLit(StaticService.serviceType == ThreadService)
      var isThreadServiceAutoStart = newLit(StaticService.autoStart)
      add backendNode, quote do:
        when isMainModule and not `isThreadService.`:
          # Boot the service provider as a
          # standalone service using the built-in web server
          var p = initOptParser(commandLineParams())
          p.next() # skip the binary name
          var port = Port(0)
          for kind, key, val in p.getOpt():
            case kind
            of cmdShortOption, cmdLongOption:
              if key in ["p", "port"]:
                port = Port(parseInt(val))
            else: discard
          
          displayInfo("Starting Service Provider")
          displayInfo("Available at http://127.0.0.1:" & $(port))
          
          # Start the  web server
          onRequestHandle()
          webserver.runServer(onRequest, nil, port)
        else:
          if `isThreadServiceAutoStart.`:
            block:
              var thrService: Thread[void]
              onRequestHandle()
              proc runThreadService {.thread.} =
                # the thread proc handling the service
                {.gcsafe.}:
                  webserver.runServer(onRequest, nil, Port(9000))
              
              # Create a thread for the service
              createThread(thrService, runThreadService)
              
              # Log service start info
              display(
                span((`serviceName.` & " Service").indent(4)),
                green("[thread]"),
              )
              sleep(100) # allow some time for the thread to start
          # else:
          #   # When the service is not set to `autoStart`
          #   # we just define the `onRequest` handler
          #   proc startService*() =
          #     onRequestHandle()
              

      #
      # Client-side API
      #
      var httpClientId = ident(StaticService.name & "Client")
      add clientHandle, quote do:
        import std/[json, asyncdispatch]
        import pkg/jsony
        import pkg/supranim/support/httpclient
        # we use a modified version of `httpclient`
        # that can handle HTTP operations over Unix Sockets

      add clientHandle, quote do:
        type
          ServiceProviderClient* {.inject.} = object of RootObj
            base: AsyncHttpClient
          ApiServiceProviderResponse*[T] {.inject.} = object
          SessionClient* {.inject.} = object of ServiceProviderClient
          # todo finish generate client-side API based on macros

    if not clientNode.isNil:
      # In case we have any other client nodes
      add clientHandle, clientNode

    case StaticService.serviceType
    of ThreadService:
      # Thread Services live in their own threads
      when isMainModule:
        error("ServiceManager - Thread Services cannot be built as standalone services")
      add serverHandle, backendNode
      # ServiceManagerThreadServices[StaticService.name] = serverHandle
      # ServiceManagerThreadServices[StaticService.name] = serverHandle
      add result, serverHandle

      let hashid = $(toMD5(instantiationInfo(fullPaths = true).filename))
      for fnEndpoint in clientSideRoutePaths:
        var routePath =
          if fnEndpoint[2].params.isSome():
            fnEndpoint[2].path.multiReplace(("{", "$"), ("}", ""), (":", "_"))
          else:
            fnEndpoint[2].path
        # if fnEndpoint[2].params.isSome():
          # var params = fnEndpoint[2].params.get().mapit((it[0]))
          # for p in fnEndpoint[2].params.get():
          #   echo p
        let routePathNode = newLit(routePath)
        var httpClientSideFunctionBody = newStmtList()
        add httpClientSideFunctionBody, quote do:
          let path {.inject.} = `routePathNode.`
          let res {.inject.}: AsyncResponse = await request(client.base, path)
          let resBody {.inject.} = await res.body

        var toObject = ident("JsonNode")
        add httpClientSideFunctionBody, quote do:
          let x {.inject.} = fromJson(resBody, `toObject.`)

        var endpointHandleNode = newProc(
          nnkPostFix.newTree(
            ident"*", ident(fnEndpoint[0])
          ),
          params = [
            nnkBracketExpr.newTree(
              ident"Future",
              nnkBracketExpr.newTree(
                ident"ApiServiceProviderResponse",
                ident"SessionClient"
              )
            ),
            nnkIdentDefs.newTree(
              ident"client",
              ident"SessionClient",
              newEmptyNode()
            )
          ],
          pragmas = nnkPragma.newTree(ident"async"),
          body = httpClientSideFunctionBody
        )
        add clientHandle, endpointHandleNode
      ServiceManagerThreadServicesClients[hashid] = clientHandle
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
    of ChannelService:
      # Channel Services are built as part of the main app.
      # add serverHandle, routesNode
      add serverHandle, backendNode
      add serverHandle, clientHandle
      add result, serverHandle
    else:
      add serverHandle, backendNode
      add result, 
        nnkWhenStmt.newTree(
          # Building a standalone Service using `serverHandle`
          nnkElifBranch.newTree(
            ident"isMainModule",
            serverHandle
          ),
          # Expose Service API to `clientHandle`,
          # at the main app-level
          nnkElse.newTree(clientHandle)
        )
    when defined supraDebugServiceProviderCode:
      echo result.repr
  createService(id, config)
  
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
