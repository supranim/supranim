## Runnable standalone WebService example.
## Build: `clue build examples/services_web.nim --out:/tmp/greeter`
## Run: `/tmp/greeter` (serves HTTP on :8765, `--port=` overrides it)
## Try:
##   curl http://127.0.0.1:8765/
##   curl http://127.0.0.1:8765/hello/nim
import supranim/microservice

initService Greeter[WebService]:
  description = "Hello microservice example"
  port = 8765

  routes do:
    get "/hello":
      req.respond(200, %*{"message": "hello from a standalone service"})

    get "/hello/{name:slug}":
      req.respond(200, %*{"message": "hello " & req.params["name"]})
