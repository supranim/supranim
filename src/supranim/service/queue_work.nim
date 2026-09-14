#
# Supranim is a high-performance web framework for building
# web applications and microservices in Nim
#
#   (c) 2026 LGPL-v3-or-later License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#

## Minimal `queue:work` bridge: execute `QueueRegistry` jobs on a
## `supranim_tasks` `TaskManager`.
##
## `startQueueWorker` registers a repeating task that polls
## `queue_jobs` every `intervalMs`, claims due rows, and runs each
## claimed job's registered `handle` on the pool dispatch thread. A
## successful run deletes the row; a failing run re-queues it
## (`now + backoff`, attempts bumped) until `tries` runs out, then
## moves it to `failed_queue_jobs`. Unknown job names fail the same
## way instead of crashing the worker.
##
## Driver-agnostic by construction: the worker is a template expanded
## in application scope (same trick as the `job` macro and
## `controller.isAuth`), so `withDBPool` and the `sql` query builder
## resolve against whichever ozark driver the app imported. Import a
## driver before use (models are only needed for `dispatch*` and
## table setup):
##
## .. code-block:: nim
##   import pkg/ozark/driver/sqlite
##   import pkg/supranim/service/queue_work
##
##   startQueueWorker(getJobsPool(), queueName = "emails")
##
## Raw SQL on purpose: ozark's DML macros finalize through `exec`,
## which splices `repr` of the value nodes into generated code — that
## breaks on template-hygienized identifiers (a loop variable arrives
## as ``c`gensym0`` and no longer parses), `where` only supports
## `=` / `!=`, and the `UPDATE` path is broken in 0.1.6 regardless.
## Plain `dbcon.exec` / `getAllRows` take runtime values, so template
## locals are safe, and the poll gets a real
## `available_at <= now ORDER BY priority, available_at LIMIT n`
## predicate. Table/column names mirror `queue/model` (`getTableName`
## lowercases + underscores); keep them in sync if the models change.
##
## Minimal on purpose: the claim is read-only, so delivery is
## at-least-once — keep one worker per queue and `intervalMs`
## comfortably above handle time, or overlapping ticks may
## double-run a job. `timeout` is advisory only (a stuck handler
## stalls that queue's delivery — handlers run synchronously on the
## dispatch thread); `priority` only orders the poll; attempts bump
## at settle time, so a crash between claim and settle replays
## without counting.

import std/strutils
import supranim_tasks
import supranim/service/queue as qjobs

type
  ClaimedQueueJob* = object
    ## One claimed queue row. Plain values only, so the poll job may
    ## hand a seq of these to the dispatch thread (no refs cross).
    ## `priority`/`chainNext`/`batchId`/`createdAt` ride along
    ## verbatim so a re-queue preserves them.
    id*: string
    queue*: string
    jobName*: string
    payload*: string
    attempts*: int
    maxTries*: int
    backoff*: int
    priority*: string
    chainNext*: string
    batchId*: string
    createdAt*: string

proc toIntOr*(s: string, default: int): int =
  ## Parse ozark's string-mapped integer columns defensively
  ## (`NULL` reads back as `""`).
  try:
    strutils.parseInt(s)
  except ValueError:
    default

template startQueueWorker*(m: TaskManager, queueName: string = "default",
    intervalMs: int = 1000, batch: int = 1,
    workerName: string = "queue-work"): TimerId =
  ## Poll `queueName` every `intervalMs`, claiming up to `batch` due
  ## rows per tick (`available_at <= now`, ordered by
  ## `priority, available_at`), and run them through
  ## `QueueRegistry`. Returns the repeating task id; stop it with
  ## `stopQueueWorker` (or `removeTask(workerName)`). The claim is
  ## read-only (no lease write exists) — see the module header for
  ## the at-least-once consequences.
  ##
  ## The poll runs on a pool worker, each `handle` on the pool
  ## dispatch thread: lock shared state there, and keep `handle`
  ## bodies free of `ref` captures like any tasks callback.
  ##
  ## NB: the template params are deliberately not named `queue` /
  ## `name` — those identifiers also appear as an object field label
  ## and a call-site label in the body, and template substitution
  ## would clobber them with the argument literal.
  block:
    let pollJob = proc(): seq[ClaimedQueueJob] {.closure.} =
      let now = qjobs.queueNowUnix()
      var claimed: seq[ClaimedQueueJob] = @[]
      block:
        withDBPool do:
          # `LIMIT` is interpolated, not bound: it is our own int, and
          # sqlite will not take a bound parameter there on all builds.
          let rows = dbcon.getAllRows(sql(
            "SELECT id, queue, job_name, payload, attempts, max_tries," &
            " available_at, priority, chain_next, batch_id, created_at" &
            " FROM queue_jobs WHERE queue = ? AND available_at <= ?" &
            " ORDER BY priority, available_at LIMIT " & $max(batch, 0)),
            queueName, $now)
          for row in rows:
            # Row policy comes from the registry entry: rows carry
            # `max_tries` (frozen at dispatch) but no `backoff`
            # column. Unknown names get the macro defaults and fail at
            # settle time. The registry is startup-written and
            # read-only afterwards, so worker-thread reads are safe —
            # register jobs before starting the worker.
            var maxTries = queue_work.toIntOr(row[5], 3)
            var backoff = 60
            if qjobs.QueueRegistry.hasKey(row[2]):
              let entry = qjobs.QueueRegistry[row[2]]
              maxTries = entry.tries
              backoff = entry.backoff
            claimed.add(ClaimedQueueJob(id: row[0], queue: row[1],
              jobName: row[2], payload: row[3],
              attempts: queue_work.toIntOr(row[4], 0),
              maxTries: maxTries, backoff: backoff,
              priority: row[7], chainNext: row[8], batchId: row[9],
              createdAt: row[10]))
      claimed
    let deliverCb = proc(jobs: seq[ClaimedQueueJob]) {.closure.} =
      for c in jobs:
        if not qjobs.QueueRegistry.hasKey(c.jobName):
          block:
            withDBPool do:
              dbcon.exec(sql(
                "INSERT INTO failed_queue_jobs (queue, job_name," &
                " payload, attempts, error, failed_at)" &
                " VALUES (?,?,?,?,?,?)"),
                c.queue, c.jobName, c.payload, $c.attempts,
                "unknown job: " & c.jobName, $(qjobs.queueNowUnix()))
          block:
            withDBPool do:
              dbcon.exec(sql"DELETE FROM queue_jobs WHERE id = ?", c.id)
          continue
        try:
          qjobs.QueueRegistry[c.jobName].handle(qjobs.parseJson(c.payload))
          block:
            withDBPool do:
              dbcon.exec(sql"DELETE FROM queue_jobs WHERE id = ?", c.id)
        except CatchableError as err:
          # Bump here (not at claim): a crash between claim and
          # settle replays without counting.
          let tries = c.attempts + 1
          block:
            withDBPool do:
              dbcon.exec(sql"DELETE FROM queue_jobs WHERE id = ?", c.id)
          if tries >= c.maxTries:
            block:
              withDBPool do:
                dbcon.exec(sql(
                  "INSERT INTO failed_queue_jobs (queue, job_name," &
                  " payload, attempts, error, failed_at)" &
                  " VALUES (?,?,?,?,?,?)"),
                  c.queue, c.jobName, c.payload, $tries, err.msg,
                  $(qjobs.queueNowUnix()))
          else:
            block:
              withDBPool do:
                dbcon.exec(sql(
                  "INSERT INTO queue_jobs (queue, job_name, payload," &
                  " attempts, max_tries, available_at, priority," &
                  " chain_next, batch_id, created_at)" &
                  " VALUES (?,?,?,?,?,?,?,?,?,?)"),
                  c.queue, c.jobName, c.payload, $tries, $c.maxTries,
                  $(qjobs.queueNowUnix() + c.backoff), c.priority,
                  c.chainNext, c.batchId, c.createdAt)
    let pollErr = proc(err: ref CatchableError) {.closure.} =
      echo "queue worker poll failed: ", err.msg
    supranim_tasks.submitRepeating(m, intervalMs, pollJob, deliverCb,
      pollErr, name = workerName)

proc stopQueueWorker*(m: TaskManager, workerName: string = "queue-work") =
  ## Stop the worker started by `startQueueWorker` (frees the name
  ## for reuse). A tick already running finishes first.
  m.removeTask(workerName)
