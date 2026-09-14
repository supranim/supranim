## ThreadService example: a job-thread that uppercases payloads.
##
## Thread services cannot be built standalone, so the service lives here
## and `examples/services_thread.nim` (the main program) imports it,
## starts it, exchanges messages and stops it.

import std/strutils
import supranim/application
import supranim/core/services

initService Worker[ThreadService]:
  description = "Uppercase worker thread"
  queueSize = 32
  autoStart = false

  thread do:
    let ch = getWorkerChannel()
    while true:
      let msg = ch[].recv()
      if isServiceStop(msg):
        break
      ch[].send(ServiceMsg(id: msg.id, action: "done:" & msg.action,
        payload: msg.payload.toUpperAscii()))

  api do:
    proc submit*(app: Application, action, payload: string,
        id: int64 = 0): bool =
      ## Queue one job for the worker. Returns false when the queue is full.
      app.sendServiceMsg("Worker", action, payload, id)
