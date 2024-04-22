import std/[options, sequtils, typeinfo]
import ../service
import pkg/emitter

export Event, Args
export typeinfo

newService Events[Inproc]:
  commands = [
    emitEvent
  ]
  
  before:
    if Event == nil:
      Event.init()

proc emitEvent(eventid: string) {.command.} =
    # if recv.len > 2:
    #   let args = recv[2..^1].mapIt(newArg(it))
    #   Event.emit(recv[1], args)
    # else:
    Event.emit(eventid)


runService do:
  template event*(id: string, handle: emitter.Callback) =
    ## Add a new listener `id` with `handle` callback
    Event.listen(id, handle)

  template emit*(id: string, args: seq[string] = @[]) =
    ## Emit an event by `id`
    block:
      var argsx = args
      sequtils.insert(argsx, [id], 0)
      let x = execEmitEvent(argsx)
