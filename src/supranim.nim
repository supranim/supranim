#
# Supranim is a high-performance web framework for building
# web applications and microservices in Nim
# 
#   (c) 2026 LGPL-v3-or-later License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#

## 
## Supranim performs many automatic setups, from macro-based initializers to
## automatic discovery of service providers and other Nim modules.
## 
## This file is the main entry point for the Supranim application and is responsible
## for bootstrapping the application, loading configurations, and starting the server.
## 

import std/[options, asyncdispatch, asynchttpserver,
      httpcore, osproc, os, strutils, sequtils, critbits,
      posix_utils, uri, macros, macrocache, times]

from std/net import Port, `$`
from std/nativesockets import Domain

import pkg/kapsis/framework
import pkg/kapsis/interactive/prompts

import ./supranim/core/[application, router, fileserver, utils]
import ./supranim/controller
import ./supranim/network/[webserver, websocket]
import ./supranim/service/events

export application, webserver, websocket,
        router, fileserver, strutils,
        prompts

export events, countProcessors
export Domain, Port, `$`, releaseUnusedMemory

macro runBaseMiddlewares*(req, res) =
  ## Executes the registered base middlewares in order. If any middleware returns false,
  ## it means that the request has been handled and we should not continue processing it.
  result = newStmtList()
  for mKey, mProc in baseMiddlewares:
    var baseMiddlewareCall = ident(mKey)
    add result, quote do:
      if unlikely(req.raw == nil):
        # this means that the request has been dropped by
        # a base middleware and we should not continue processing it.
        return

      if `baseMiddlewareCall`(req, res) == false:
        # if a base middleware returns false, it means that
        # the response has been sent or the request has been dropped
        # and we should not continue processing the request
        # or run any more base middlewares.
        return

#
# Httpbeast Wrapper
#
template getBaseMiddlewares*(req, res) {.dirty.} =
  ## Walk through the registered base middlewares and execute them in order.
  if unlikely(req.raw == nil):
    # this means that the request has been dropped by a base middleware
    # and we should not continue processing it.
    return
  when not defined httpbench:
    runBaseMiddlewares(req, res)

template run*(app: Application, optionalBlock: untyped) {.dirty.} =
  ## Runs the Supranim application server
  ## 
  ## This is the main entry point for starting the application. It sets up the
  ## HTTP server and defines the request handling logic, including routing and
  ## middleware execution.
  ## 
  ## Optionally, you can provide an `optionalBlock` of code that will be executed during the server
  ## startup process, allowing you to inject custom logic or perform additional setup before
  ## the server starts accepting requests.
  ## 
  ## For low-level server control, check the code inside this template and the `onRequest` procedure
  ## to see how requests are processed and how the server is started.
  block:
    template invoke4xxHandler(path, req, res) =
      when defined supraMicroservice:
        Router.call4xx(req.addr, res.addr)
      else:
        Router.call4xx(req, res)
      req.resp(Http404, res.getBody, res.getHeaders)
      event().emit("http.error", some(@[path, $Http404]))
      
    when defined supraWebkit:
      # Bootstrap Supranim from a web-based `WebKit` desktop application. 
      discard # todo to be implemented/documented
    else:
      # Bootstrap Supranim from a web-based application.
      proc onRequest(req: var webserver.Request) {.gcsafe.} =
        {.gcsafe.}:
          # req.send(Http200, "", newHttpHeaders()) # send 100 Continue response to the client
          # return
          var res = Response(headers: newHttpHeaders())
          getBaseMiddlewares(req, res)
          let
            path = req.getUriPath()
            httpMethod = req.getHttpMethod()
            runtimeCheck = Router.checkExists(path, httpMethod)

          # The `checkExists` method of the Router service checks if there is
          # a route that matches the incoming request's path and HTTP method.
          case runtimeCheck.exists
          of true:
            req.setParams(runtimeCheck.params)
            let middlewareStatus: HttpCode =
              runtimeCheck.route.resolveMiddleware(req, res)
            case middlewareStatus
            of Http301, Http302, Http303:
              req.resp(middlewareStatus, "", res.getHeaders())
            of Http204:
                case httpMethod
                of HttpGet:
                  when defined supraMicroservice:
                    runtimeCheck.route.callback(req.addr, res.addr)
                  else:
                    runtimeCheck.route.callback(req, res)
                  let
                    code = res.getCode()
                    headers = res.getHeaders()
                    body = res.getBody()
                  
                  # resolve afterwares
                  discard runtimeCheck.route.resolveAfterware(req, res)
                  
                  if not res.isStreaming and req.responseSent == false:
                    # when `isStreaming` is true the response is being streamed
                    # otherwise we send the full response here
                    req.resp(res.getCode, res.getBody, res.getHeaders)
                else:
                  when not defined supraMicroservice:
                    try: 
                      runtimeCheck.route.callback(req, res)
                    except Exception as e:
                      # is important to catch unexpected errors here
                      # in order to prevent the server from crashing
                      displayError("Error processing request: " & e.msg)
                      req.resp(Http500, "Internal Server Error", res.getHeaders())
                      return
                  discard runtimeCheck.route.resolveAfterware(req, res)
                  req.resp(res.getCode, res.getBody, res.headers)
            else:
              req.resp(Http403, getDefault(Http403), res.getHeaders)
              event().emit("http.error", some(@[path, $Http403]))
          of false:
            when defined webApp:
              when defined supraFileserver:
                # useful when the supranim application is running without a reverse
                # proxy in front of it, for example in development.
                # in production it's recommended to use a reverse proxy like Nginx,
                # Caddy, or Traefik to serve static assets and handle SSL termination.
                var hasFoundResource: bool
                if app.assetsHandler != nil:
                  app.assetsHandler(req, res, hasFoundResource)
                else:
                  if startsWith(path, "/assets"): # TODO expose `/assets` route for customization
                    req.sendAssets(path, res.getHeaders(), hasFoundResource)
                if not hasFoundResource: invoke4xxHandler(path, req, res)
              else: invoke4xxHandler(path, req, res)
            else: invoke4xxHandler(path, req, res)

      # Start the HTTP server
      # let domain: Domain = parseEnum[Domain](app.config("server.type").getStr)
      event().emit("app.startup")
      
      when defined supranimUseGlobalOnRequest:
        app.server = newWebServer(Port(app.config("server.port").getInt))
      else:
        app.server = newWebServer(Port(app.config("server.port").getInt), true)
      
      # when provided, the optional block can be used to inject
      # additional logic during the server startup process
      optionalBlock

      when not compiles(startupCallback()):
        injectSafeThreadCallbacks()
      
      # Starts the actual server loop, this will block
      # the main thread and keep the server running until it's stopped.
      when defined supranimUseGlobalOnRequest:
        app.server.start(onRequest)
      else:
        when compiles(startupCallback()):
          app.server.start(onRequest, startupCallback, threads = countProcessors())
        else:
          app.server.start(onRequest, nil, threads = countProcessors())

template run*(app: Application) =
  ## Runs the Supranim application server without an optional block.
  app.run do:
    discard
