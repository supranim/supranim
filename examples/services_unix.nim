## Runnable standalone UnixService example (POSIX only).
## Build: `clue build examples/services_unix.nim --out:/tmp/localgreeter`
## Run: `/tmp/localgreeter`
## Try:
##   curl --unix-socket /tmp/supranim_example.sock http://localhost/ping
when defined(windows):
  {.error: "This example requires Unix domain sockets (POSIX)".}

import supranim/microservice

initService LocalGreeter[UnixService]:
  description = "Local IPC microservice example"
  socketPath = "/tmp/supranim_example.sock"

  routes do:
    get "/ping":
      req.respond(200, %*{"pong": true})
