# Example: WebSocket rooms with session middleware + HTML view.
#
#   Build: clue build examples/ws_rooms.nim --out:/tmp/ws_rooms
#   Run:   /tmp/ws_rooms            # serves http://127.0.0.1:8000
#
# Open http://127.0.0.1:8000/ for a session cookie, then connect a
# WebSocket client to ws://127.0.0.1:8000/chat/lobby. Messages are
# broadcast to every member of the room except the sender.

import std/[httpcore, tables, strutils]
import supranim/core/[router, request, response]
import supranim/network/webserver
import supranim/support/[ws, view, session]

proc indexHandler(req: var Request, res: var Response) {.nimcall, gcsafe.} =
  withSession do:
    respondPage("WS rooms", "<h1>Rooms</h1><p>Join <code>/chat/lobby</code> over WebSocket.</p>")

proc chatHandler(req: var Request, res: var Response) {.nimcall, gcsafe.} =
  let room = req.routeParams.getOrDefault("room", "lobby")
  discard req.upgradeWs(res,
    onOpen = proc(ws: WsConnection) =
      defaultHub().joinRoom(room, ws),
    onMessage = proc(ws: WsConnection, kind: WsFrameKind,
                     data: openArray[byte]) =
      if kind == wsText:
        defaultHub().broadcast(room, cast[string](@data), exclude = ws),
    onClose = proc(ws: WsConnection, code: int, reason: string) =
      defaultHub().leaveAllRooms(ws))

var appRouter = newHttpRouter()
appRouter.get("/", indexHandler)
appRouter.ws("/chat/{room:slug}", chatHandler, middlewares = @[requireWsSession])

proc onRequest(req: var Request) =
  {.gcsafe.}:
    var res = Response(headers: newHttpHeaders())
    if req.findHeader("Upgrade").toLowerAscii == "websocket":
      let wsHit = appRouter.checkWsExists(req.getUriPath())
      if wsHit.exists:
        req.routeParams = wsHit.params
        if wsHit.route.resolveMiddleware(req, res) == Http204:
          wsHit.route.callback(req, res)
          return
        req.resp(Http403, getDefault(Http403))
        return
    let rc = appRouter.checkExists(req.getUriPath(), req.getHttpMethod())
    if rc.exists:
      req.routeParams = rc.params
      rc.route.callback(req, res)
      if not req.responseSent:
        req.resp(res.getCode(), res.getBody(), res.getHeaders())
    else:
      req.resp(Http404, getDefault(Http404))

when defined(windows):
  var server = newWebServer()
  server.start(onRequest, nil)
else:
  var server = newWebServer(enableMultiThreading = true)
  server.start(onRequest, nil, threads = 4)
