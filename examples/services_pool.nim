## Runnable ThreadPoolService example (tasks-backed TaskManager).
## Build: `clue build examples/services_pool.nim --out:/tmp/pool`
## Run: `/tmp/pool`
import std/[locks, os]
import supranim_tasks
import supranim/application
import ./services/pool

var resLock: Lock
initLock(resLock)
var results: seq[int]

let app = appInstance()
assert startJobsService(app)
assert isJobsServiceRunning()

assert submitFib(30, proc(res: int) {.closure.} =
  withLock resLock:
    results.add(res)).isValid

# the callback fires on the pool dispatch thread, wait for delivery
var waits = 0
while waits < 500:
  var ready = false
  withLock resLock:
    ready = results.len == 1
  if ready: break
  sleep(10)
  inc waits

var fib30 = 0
withLock resLock:
  assert results.len == 1
  fib30 = results[0]
assert fib30 == 832040

assert stopJobsService(app)
assert not isJobsServiceRunning()
echo "pool ok: fib(30) = ", fib30
