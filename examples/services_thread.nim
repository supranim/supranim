## Runnable ThreadService example.
## Build: `clue build examples/services_thread.nim --out:/tmp/worker`
## Run: `/tmp/worker`
import supranim/application
import ./services/worker

let app = appInstance()
assert startWorkerService(app)
assert app.hasServiceChan("Worker")

assert submit(app, "upper", "hello world", 1)
let reply = app.recvServiceMsg("Worker")
assert reply.id == 1
assert reply.payload == "HELLO WORLD"
echo "reply: ", reply.action, " -> ", reply.payload

assert stopWorkerService(app)
echo "worker stopped, OK"
