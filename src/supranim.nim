# Supranim - A fast MVC web framework
# for building web apps & microservices in Nim.
#   (c) 2024 MIT License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim

when isMainModule:
  include ./supranim/cli/supra
else:
  import std/[options, asyncdispatch, asynchttpserver,
              httpcore, osproc, os, strutils, sequtils,
              posix_utils, uri, macros, macrocache, times]

  from std/net import Port, `$`
  from std/nativesockets import Domain
  
  import ./supranim/application
  import ./supranim/core/[http, utils]
  import ./supranim/core/http/[router, fileserver]

  from ./supranim/controller import getClientID
  export application, resp, router

  macro runBaseMiddlewares*(req, res) =
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
    # for logfpath in ["errors.4xx", "errors.5xx"]:
    #   writeFile(logsPath / logfpath, "")
    # event("errors.4xx") do(args: Args):
    #   let f = open(logsPath / "errors.4xx", fmAppend)
    #   defer: f.close()
    #   let err = "[$1] $2 - $3" % [$now(), unpack(args[0], string), unpack(args[1], string)]
    #   f.writeLine(err)
    # emit("errors.4xx")

    # event("errors.5xx") do(args: Args):
    #   let f = open(logsPath / "errors.5xx", fmAppend)
    #   defer: f.close()
    #   let err = "[$1] $2 - $3" % [$now(), unpack(args[0], string), unpack(args[1], string)]
    #   f.writeLine(err)
    when defined supraWebkit:
      # Bootstrap Supranim without a HTTP server. This is useful
      # when you want to use Supranim's MVC features without a web sever
      # in webkit-based applications that implemnets custom URL
      # schemes using Webkit/WKURLSchemeHandler
      discard # todo to be implemented/documented
    else:
      # Bootstrap Supranim's Web Server via pkg/httpbeast
      proc onRequest(req: http.Request): Future[void] =
        {.gcsafe.}:
          var req = newRequest(req, req.path.get().parseUri, req.headers())
          var res = Response(headers: newHttpHeaders())
          getBaseMiddlewares(req, res)
          let
            path = req.getUriPath()
            httpMethod = req.root.httpMethod.get()
            runtimeCheck =
              App.router.checkExists(path, httpMethod)
          case runtimeCheck.exists
          of true:
            req.params = runtimeCheck.params
            let middlewareStatus: HttpCode =
              runtimeCheck.route.resolveMiddleware(req, res)
            case middlewareStatus
            of Http301, Http302, Http303:
              req.root.resp(middlewareStatus, "", res.getHeaders())
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
                  req.root.resp(res.getCode, res.getBody, res.getHeaders)
                else:
                  when not defined supraMicroservice:
                    runtimeCheck.route.callback(req, res)
                  req.root.resp(res.getCode, res.getBody, res.getHeaders)
            else:
              req.root.resp(Http403, getDefault(Http403), $getContentType())
          of false:
            when defined webApp:
              when defined supranimServeFiles:
                # serves static assets while in development mode
                var hasFoundResource: bool
                if strutils.startsWith(path, "/assets"):
                  req.root.serveStaticFile(path,
                    res.getHttpHeaders(),
                    hasFoundResource
                  )
                if not hasFoundResource:
                  when defined supraMicroservice:
                    App.router.call4xx(req.addr, res.addr)
                  else:
                    App.router.call4xx(req, res)
                  req.root.resp(Http404, res.getBody, res.getHeaders)
              else:
                when defined supraMicroservice:
                  App.router.call4xx(req.addr, res.addr)
                else:
                  App.router.call4xx(req, res)
                req.root.resp(Http404, res.getBody, res.getHeaders)
          freemem(req)
          freemem(res)

      let domain: Domain = parseEnum[Domain](App.config("server.type").getStr)
      let settings =
        initSettings(
          port = Port(App.config("server.port").getInt),
          bindAddr = App.config("server.address").getStr,
          domain = domain,
          numThreads = 1,
          startup = startupCallback # pre-declared in `application.nim`
      )
      # event("httpserver_boot") do(args: Args):
        # echo("Starting ", settings.numThreads, " threads")
        # echo("Running at http://", settings.bindAddr, ":", $(settings.port))
      # emit("httpserver_boot")
      http.runServer(onRequest, settings)

