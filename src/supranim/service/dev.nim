# Supranim is a simple MVC web framework
# for building web apps & microservices in Nim.
#
# (c) 2024 MIT License | Made by Humans from OpenPeeps
# https://supranim.com | https://github.com/supranim

import ../service

import std/options
export options, ZSendRecvOptions

provider Devtool, ServiceType.RouterDealer:
  # Initializes Devtool Service Provider
  port = 55002
  commands = [
    devtoolCheckSocket
  ]

handlers:
  devtoolCheckSocket do:
    echo recv[1]
    server.sendAll("hey")

backend:
  import std/[json, jsonutils, asyncdispatch, asynchttpserver]
  import supranim/core/utils
  import pkg/ws
  type
    HeartBeatService = object
      id: string
    HeartBeat = ref object
      services: seq[HeartBeatService]
  var hb = HeartBeat(services: @[HeartBeatService(id: "TimEngine")])
  proc devserver() {.thread.} =
    proc cb(req: Request) {.async.} =
      {.gcsafe.}:
        if req.url.path == "/ws":
          var wsc: WebSocket
          try:
            wsc = await newWebSocket(req)
            while wsc.readyState == Open:
              await wsc.send($(toJson(hb)))
              # await sleepAsync(500)
            freemem(wsc)
          except WebSocketClosedError:
            echo "Socket closed."
            freemem(wsc)
          except WebSocketProtocolMismatchError:
            echo "Socket tried to use an unknown protocol: ", getCurrentExceptionMsg()
          except WebSocketError:
            echo "Unexpected socket error: ", getCurrentExceptionMsg()
        await req.respond(Http503, "")
        freemem(req)
    var server = newAsyncHttpServer()
    waitFor server.serve(Port(9001), cb)
  var thr: Thread[void]
  createThread(thr, devserver)

frontend:
  proc checkDevSession*() =
    let some = cmd(devtoolCheckSocket, @["hello"])