#
# Supranim is a full-featured web framework for building
# web apps & microservices in Nim.
# 
#   (c) 2025 MIT License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#

when isMainModule:
  # builds Supra, Supranim's command line interface
  include ./supranim/cli/supra
else:
  # expose Supranim Framework API as a library
  import std/[options, asyncdispatch, asynchttpserver,
        httpcore, osproc, os, strutils, sequtils,
        posix_utils, uri, macros, macrocache, times]

  from std/net import Port, `$`
  from std/nativesockets import Domain
  
  import pkg/kapsis/cli
  
  import ./supranim/core/utils
  import ./supranim/[application, controller]
  import ./supranim/http/[webserver, websocket, router, fileserver]
  import ./supranim/service/events

  export application, router
  
  macro runBaseMiddlewares*(req, res) =
    ## This macro is used to run the base middlewares
    ## for the application
    result = newStmtList()
    for mKey, mProc in baseMiddlewares:
      add result,
        nnkBlockStmt.newTree(
          newEmptyNode(),
          nnkStmtList.newTree(
            nnkCaseStmt.newTree(
              newCall(
                ident(mKey),
                req,
                res
              ),
              nnkOfBranch.newTree(
                ident("Http200"),
                newStmtList().add(nnkCommand.newTree(ident("echo"), newLit("x")))
              ),
              nnkElse.newTree(
                newStmtList().add(nnkDiscardStmt.newTree(newEmptyNode()))
              )
            )
          )
        )

  #
  # Httpbeast Wrapper
  #
  template getBaseMiddlewares(req, res) =
    runBaseMiddlewares(req, res)

  template run*(App: Application) =
    # runs the application
    
    template invoke4xxHandler(path, req, res) =
      when defined supraMicroservice:
        App.router.call4xx(req.addr, res.addr)
      else:
        App.router.call4xx(req, res)
      req.resp(Http404, res.getBody, res.getHeaders)
      emitter("http.error", some(@[path, $Http404]))
      
    when defined supraWebkit:
      # Bootstrap Supranim from a web-based `WebKit` desktop application. 
      discard # todo to be implemented/documented
    else:
      # Bootstrap Supranim from a web-based application.
      proc onRequest(req: var webserver.Request) {.gcsafe.} =
        {.gcsafe.}:
          var res = Response(headers: newHttpHeaders())
          getBaseMiddlewares(req, res)
          let
            path = req.getUriPath()
            httpMethod = req.getHttpMethod()
            runtimeCheck =
              App.router.checkExists(path, httpMethod)
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
                    # App.controllers("getTestpage").exec(req.addr, res.addr)
                    runtimeCheck.route.callback(req.addr, res.addr)
                  else:
                    runtimeCheck.route.callback(req, res)
                  let
                    code = res.getCode()
                    headers = res.getHeaders()
                    body = res.getBody()
                  
                  # resolve afterwares
                  discard runtimeCheck.route.resolveAfterware(req, res)
                  
                  if not res.isStreaming:
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
              emitter("http.error", some(@[path, $Http403]))
          of false:
            let runtimeCheck = App.router.checkWsExists(path)
            if runtimeCheck.exists:
              # if req.raw.isWebSocketUpgrade():
                # discard 
                # discard evhttp_set_cb(httpd, "/live", ws_upgrader, nil)
                # runtimeCheck.route.callback(req, res)
                # acceptWebSocketHandle(
                #   wsPools,
                #   path,
                #   req.raw,
                #   onOpen = onOpen,
                #   onMessage = onMessage,
                #   onClose = onClose
                # )
                # return # important to prevent further processing
              req.resp(Http400, getDefault(Http400), res.getHeaders)
              emitter("http.error", some(@[path, $Http400]))
            else:
              when defined webApp:
                when defined supraFileserver:
                  # useful when the supranim application is running
                  # without a proxy server in front of it.
                  var hasFoundResource: bool
                  if strutils.startsWith(path, "/assets"): # expose `/assets` route for customization
                    req.sendAssets(path, res.getHeaders(), hasFoundResource)
                  if not hasFoundResource:
                    invoke4xxHandler(path, req, res)
                else:
                  invoke4xxHandler(path, req, res)
              else:
                invoke4xxHandler(path, req, res)
          discard releaseUnusedMemory() # free up memory after each request

      # Start the HTTP server
      let domain: Domain = parseEnum[Domain](App.config("server.type").getStr)
      emitter("app.startup")

      when defined supraServerMummy:
        http.runServer(onRequest)
      else:
        # standard web server startup
        var server = newWebServer(Port(app.config("server.port").getInt))
        server.start(onRequest, startupCallback)