#
# Worker round-trip tests: dispatch -> queue_work poll -> handle runs
# -> row settled (deleted / retried / failed). sqlite-backed.
#
import std/[unittest, json, os, locks, times]

import supranim_tasks
import supranim/service/queue
import supranim/queue/model
import supranim/service/queue_work

import pkg/ozark/driver/sqlite

var testLock: Lock
initLock(testLock)
var handled: seq[int]
var flakyRuns: int

job WorkHello:
  queue = "workq"
  tries = 3
  backoff = 1
  timeout = 30

  payload:
    n: int

  handle(payload):
    withLock testLock:
      handled.add(payload.n)

job WorkFlaky:
  queue = "workq"
  tries = 2
  backoff = 1
  timeout = 30

  payload:
    n: int

  handle(payload):
    withLock testLock:
      inc flakyRuns
    raise newException(CatchableError, "boom")

template waitDone(cond: untyped, timeoutMs: int = 15000): bool =
  var attemptsLeft = timeoutMs div 20
  var condMet = false
  while attemptsLeft > 0:
    withLock testLock:
      condMet = cond
    if condMet: break
    sleep(20)
    dec attemptsLeft
  condMet

proc queueCount(queueName: string): int =
  block:
    withDBPool do:
      let rows = Models.table(QueueJobs).selectAll()
        .where("queue", queueName).getAll()
      return rows.len
  0

proc failedCount(): int =
  block:
    withDBPool do:
      let rows = Models.table(FailedQueueJobs).selectAll().getAll()
      return rows.len
  0

proc wipeTables() =
  block:
    withDBPool do:
      Models.table(QueueJobs).dropTable().exec()
      Models.table(QueueJobs).prepareTable().exec()
  block:
    withDBPool do:
      Models.table(FailedQueueJobs).dropTable().exec()
      Models.table(FailedQueueJobs).prepareTable().exec()
  withLock testLock:
    handled.setLen(0)
    flakyRuns = 0

let dbPath = getTempDir() / "supranim_queue_work_test.db"
if fileExists(dbPath):
  removeFile(dbPath)
initOzarkDatabase(dbPath)
initOzarkPool(3)
block:
  withDBPool do:
    # WAL: readers never block writers. The worker polls (reads) on
    # its thread while settling (writes) on dispatch and the test
    # asserts (reads) on main — rollback-journal mode deadlocks that
    # trio with "database is locked". Persistent per db file.
    dbcon.exec(sql"PRAGMA journal_mode=WAL")
    Models.table(QueueJobs).prepareTable().exec()
    Models.table(FailedQueueJobs).prepareTable().exec()

suite "queue worker":
  test "dispatched job runs and the row is deleted":
    wipeTables()
    dispatchWorkHello(WorkHelloPayload(n: 7), onQueue = "t1")
    check queueCount("t1") == 1
    var m = newTaskManager(poolSize = 2)
    let wid = startQueueWorker(m, queueName = "t1", intervalMs = 100, batch = 5)
    check m.hasTask(wid)
    check waitDone(handled == @[7])
    sleep(300) # let the settle delete land
    check queueCount("t1") == 0
    check failedCount() == 0
    stopQueueWorker(m)
    m.close()

  test "delayed dispatch waits for availability":
    wipeTables()
    dispatchWorkHello(WorkHelloPayload(n: 9), delay = 2, onQueue = "t2")
    var m = newTaskManager(poolSize = 2)
    discard startQueueWorker(m, queueName = "t2", intervalMs = 100, batch = 5)
    sleep(1000)
    withLock testLock:
      check handled.len == 0 # not due yet
    check queueCount("t2") == 1
    check waitDone(handled == @[9])
    sleep(300)
    check queueCount("t2") == 0
    stopQueueWorker(m)
    m.close()

  test "failing job retries then lands in failed table":
    wipeTables()
    dispatchWorkFlaky(WorkFlakyPayload(n: 1), onQueue = "t3")
    var m = newTaskManager(poolSize = 2)
    discard startQueueWorker(m, queueName = "t3", intervalMs = 100, batch = 5)
    check waitDone(failedCount() == 1) # tries=2, backoff=1
    withLock testLock:
      check flakyRuns == 2 # ran exactly `tries` times
    check queueCount("t3") == 0
    block:
      withDBPool do:
        let rows = Models.table(FailedQueueJobs).selectAll().getAll()
        check rows.len == 1
        check rows[0].job_name == "WorkFlaky"
        check rows[0].attempts == "2"
        check rows[0].error == "boom"
    stopQueueWorker(m)
    m.close()

  test "unknown job name fails the row instead of crashing":
    wipeTables()
    block:
      withDBPool do:
        Models.table(QueueJobs).insert({
          "queue": "t4",
          "job_name": "Nope",
          "payload": """{"n":1}""",
          "attempts": "0",
          "max_tries": "3",
          "available_at": $queueNowUnix(),
          "priority": "0",
          "chain_next": "",
          "batch_id": "",
          "created_at": $queueNowUnix()}).exec()
    var m = newTaskManager(poolSize = 2)
    discard startQueueWorker(m, queueName = "t4", intervalMs = 100, batch = 5)
    check waitDone(failedCount() == 1)
    check queueCount("t4") == 0
    block:
      withDBPool do:
        let rows = Models.table(FailedQueueJobs).selectAll().getAll()
        check rows.len == 1
        check rows[0].error == "unknown job: Nope"
    stopQueueWorker(m)
    m.close()
