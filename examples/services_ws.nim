## Runnable standalone websocket service example.
## Build: `clue build examples/services_ws.nim --out:/tmp/echows`
## Run: `/tmp/echows` (serves ws://127.0.0.1:8766, `--port=` overrides it)
import supranim/microservice

initService Echo[WebService]:
  description = "WebSocket echo example"
  port = 8766

  ws do:
    wss.onOpen(proc(ws: WsConnection) {.closure.} =
      echo "ws client connected"
    )
    wss.onMessage(proc(ws: WsConnection, kind: WsFrameKind,
        data: openArray[byte]) {.closure.} =
      if kind == wsText:
        ws.sendText("echo: " & cast[string](data))
    )
    wss.onClose(proc(ws: WsConnection, code: int,
        reason: string) {.closure.} =
      echo "ws client left: ", code, " ", reason
    )
