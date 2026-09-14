## Singleton service example: an in-process hit counter.
##
## Services cannot be defined in the main module, so the service lives
## here and `examples/services_counter.nim` (the main program) imports it.

import supranim/core/services

initService Counter[Singleton]:
  description = "In-process hit counter"
  state do:
    type Counter = object
      hits: int
  api do:
    proc counter*(): ptr Counter =
      ## Return the singleton instance, creating it on first use
      getCounterInstance(
        proc(instance: ptr Counter) =
          {.gcsafe.}:
            instance[] = Counter(hits: 0)
      )

    proc hit*() =
      ## Record one hit
      inc counter()[].hits

    proc hits*(): int =
      ## Total hits recorded
      counter()[].hits
