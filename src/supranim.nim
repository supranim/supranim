# Supranim is a simple MVC web framework
# for building web apps & microservices in Nim.
#
# (c) 2024 MIT License | Made by Humans from OpenPeeps
# https://supranim.com | https://github.com/supranim

import std/[options, asyncdispatch, asynchttpserver,
            httpcore, osproc, os, strutils, sequtils,
            posix_utils, uri, macros, macrocache]

import ./supranim/application
import ./supranim/service/[dev, events]
import ./supranim/core/[http, router, utils]

from std/net import Port, `$`

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

template run*(app: Application) =
  proc onRequest(req: http.Request): Future[void] =
    {.gcsafe.}:
      var req = newRequest(req, parseUri(req.path.get()))
      req.initRequestHeaders()
      var res = Response(headers: newHttpHeaders())
      getBaseMiddlewares(req, res)
      let path = req.getUriPath()
      let runtimeCheck = Router.checkExists(path, req.root.httpMethod.get())
      case runtimeCheck.exists
      of true:
        # if fixTrailSlash:
        #   res.addHeader("Location", reqPath)
        #   req.root.resp(code = HttpCode(301), "", res.getHeaders())
        let middlewareStatus: HttpCode = runtimeCheck.route.resolveMiddleware(req, res)
        case middlewareStatus
        of Http200:
          discard runtimeCheck.route.callback(req, res, app)
          req.root.resp(res.getCode(), res.getBody(), res.getHeaders())
        of Http301, Http302, Http303:
          req.root.resp(middlewareStatus, "", res.getHeaders())
        else:
          req.root.resp(Http403, getDefault(Http403), $getDefaultContentType())
      of false:
        var isStaticFile: bool
        when defined webApp:
          when not defined release:
            # serves static assets while in development mode
            if strutils.startsWith(path, "/assets"):
              if fileExists(storagePath / path):
                isStaticFile = true
                let contents = readFile(storagePath / path)
                let mimetype = 
                  case path.splitFile.ext
                  of ".js":
                    "Content-Type: application/javascript; charset=utf-8"
                  of ".css":
                    "Content-Type: text/css; charset=utf-8"
                  of ".svg":
                    "Content-Type: image/svg+xml"
                  else:
                    # filetype.match(contents).mime.value
                    ""
                req.root.resp(code = Http200, contents, mimetype)
        if not isStaticFile:
          events.emit("errors.404")
          Router.call4xx(req, res, app)
          req.root.resp(Http404, res.getBody(), res.getHeaders())
      freemem(req)
      freemem(res)
  
  proc startup() =
    initRouter()
    initRouterErrorHandlers() # register 4xx/5xx error handlers

  let settings = initSettings(
    Port(app.config("server", "port").getInt),
    app.config("server", "address").getString,
    app.config("server", "threads").getInt,
    startup
  )
  echo("Starting ", settings.numThreads, " threads")
  echo("Running at http://", settings.bindAddr, ":", $(settings.port))
  http.runServer(onRequest, settings)
