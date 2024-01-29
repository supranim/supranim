import std/[options, typeinfo]
import ../service
import pkg/emitter

export Event, Arg

provider Events, ServiceType.InProcess:
  commands = [
    eventEmit
  ]

handlers:
  eventEmit do:
    if recv.len > 2:
      Event.emit(recv[1], @[newArg(recv[2])])
    else:
      Event.emit(recv[1])
    server.send("")

backend:
  if Event == nil:
    Event.init()

frontend:
  template listen*(id: string, handle: emitter.Callback) =
    Event.listen(id, handle)

  template emit*(id: string) =
    let x = eventEmit.cmd([id])