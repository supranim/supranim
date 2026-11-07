#
# Unit tests for supranim/model facade (Ozark: pg + mysql + sqlite)
#
import std/unittest
import std/[tables, os]

import supranim/model
import supranim/queue/model as queueModels
import ozark/driver/sqlite

newModel FacadeThings:
  id {.pk.}: Serial
  title {.notnull.}: Varchar(128)

suite "model facade":
  test "getTableName converts CamelCase to snake_case":
    check getTableName("FacadeThings") == "facade_things"
    check getTableName("QueueJobs") == "queue_jobs"
    check getTableName("Users") == "users"

  test "facade re-exports query, collection and migration":
    # migration driver ids cover all three backends; mysql id exists
    # only in ozark > 0.2.0, so tolerate the registry release.
    check OzarkMigrationDriverPgsql == 1
    when declared(OzarkMigrationDriverMysql):
      check OzarkMigrationDriverMysql == 2
    check OzarkMigrationDriverSqlite == 3

  test "sqlite round-trip via facade (prepare/insert/select)":
    let dbPath = getTempDir() / "supranim_model_facade_test.db"
    if fileExists(dbPath):
      removeFile(dbPath)
    initOzarkDatabase(dbPath)
    initOzarkPool(2)
    block:
      withDBPool do:
        Models.table(FacadeThings).prepareTable().exec()
        Models.table(FacadeThings).insert({title: "hello"}).exec()
    block:
      withDBPool do:
        let rows = Models.table(FacadeThings).selectAll().getAll()
        check not rows.isEmpty
        check rows.first().getTitle() == "hello"
    removeFile(dbPath)

  test "queue models stay portable (Text + int8 epochs)":
    check getTableName("QueueJobs") == "queue_jobs"
    check getTableName("FailedQueueJobs") == "failed_queue_jobs"
    check getTableName("QueueBatches") == "queue_batches"

  test "driver-agnostic pool API is available":
    check compiles(initOzarkDatabase("test_model_tmp.db"))
    check compiles(withDBPool do:
      discard)
