#
# Unit tests for supranim queue jobs (macro + dispatch).
#
import std/[unittest, json, options, os]

import supranim/service/queue
import supranim/queue/model

import pkg/ozark/driver/sqlite

job TestWelcome:
  queue = "emails"
  tries = 5
  backoff = 30
  timeout = 60

  payload:
    userId: int
    email: string

  handle(payload):
    check payload.userId == 7
    check payload.email == "a@b.c"

suite "queue jobs":
  test "macro generates a registry entry":
    check QueueRegistry.hasKey("TestWelcome")
    let e = QueueRegistry["TestWelcome"]
    check e.queue == "emails"
    check e.tries == 5
    check e.backoff == 30
    check e.timeout == 60

  test "registry handle deserializes and runs the typed handler":
    QueueRegistry["TestWelcome"].handle(%*{"userId": 7, "email": "a@b.c"})

  test "dispatch stores a job row":
    let dbPath = getTempDir() / "supranim_queue_test.db"
    if fileExists(dbPath):
      removeFile(dbPath)
    initOzarkDatabase(dbPath)
    initOzarkPool(3)
    # NB: ozark's `withDBPool` injects `const sqlDriver` in the
    # caller scope, so each use needs its own `block:`
    block:
      withDBPool do:
        Models.table(QueueJobs).prepareTable().exec()
        Models.table(FailedQueueJobs).prepareTable().exec()
        Models.table(QueueBatches).prepareTable().exec()
    # NB: `dispatch*` opens its own `withDBPool`, never call it
    # from inside another `withDBPool` block (the pool would deadlock)
    dispatchTestWelcome(TestWelcomePayload(userId: 7, email: "a@b.c"))
    block:
      withDBPool do:
        let rows = Models.table(QueueJobs).selectAll().getAll()
        check not rows.isEmpty
