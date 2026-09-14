## ThreadPoolService example: a pool for CPU-bound jobs.
##
## Unlike `ThreadService` there is no worker body here. Jobs are
## submitted via the `api` handles onto a `supranim_tasks`
## `TaskManager`; they run on pool worker threads while `cb`/`onError`
## fire serialized on the pool dispatch thread (never on the main
## thread, so lock shared state there). The same manager also runs
## delayed, repeating and wall-clock scheduled tasks.
##
## The service lives outside the main module (pool services cannot
## be built standalone); `examples/services_pool.nim` drives it.

import supranim/application
import supranim/core/services

initService Jobs[ThreadPoolService]:
  description = "CPU-bound job pool example"
  poolSize = 2
  autoStart = false

  shared do:
    type FibJob = object
      n: int

  api do:
    proc fib(n: int): int =
      ## Iterative Fibonacci, our CPU-bound demo job
      var a = 0
      var b = 1
      for _ in 2..n:
        let t = a + b
        a = b
        b = t
      b

    proc submitFib*(n: int, done: proc(res: int) {.closure.}): JobId =
      ## Run `fib(n)` off the calling thread. Returns a `JobId` for
      ## `cancelJob` (`JobId(0)` when the pool is down). `done` fires
      ## on the pool dispatch thread when the result is ready.
      getJobsPool().submit(
        job = proc(): int {.closure.} = fib(n),
        cb = done,
        onError = proc(err: ref CatchableError) {.closure.} =
          echo "job failed: ", err.msg)

    proc cancelFib*(id: JobId): bool =
      ## Drop a still-queued `fib` job: true means it will never run
      ## (silent). A running or finished job returns false and
      ## delivers normally.
      getJobsPool().cancelJob(id)
