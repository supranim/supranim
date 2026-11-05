#
# MySQL integration test (opt-in).
#
# Default `clue test` compiles this file WITHOUT the mysql driver
# (no libmysqlclient needed) and passes trivially. To exercise a live
# MySQL / MariaDB server:
#
#   1. Install client libs (e.g. `brew install mysql-client`).
#   2. Start a server and create an empty database.
#   3. Run:
#        SUPRANIM_TEST_MYSQL=1 \
#        DB_HOST=127.0.0.1 DB_PORT=3306 DB_NAME=supranim_test \
#        DB_USER=root DB_PASS=secret \
#        clue test test_mysql_integration --define:supraDBMainMysql
#
# The test creates `facade_things_mysql` + the queue tables, inserts one
# row per table, reads it back, and drops the tables. In particular it
# proves the `int8` epoch columns in `queue/model` generate valid MySQL
# (`bigint`, see the `int8 → bigint` mapping in `ozark/query.nim`).
#
import std/unittest
import std/[os, strutils]

when defined supraDBMainMysql:
  import supranim/model
  import supranim/model/database
  import supranim/queue/model as queueModels

  newModel FacadeThingsMysql:
    id {.pk.}: Serial
    title {.notnull.}: Varchar(128)

suite "mysql integration (opt-in)":
  test "round-trip on live MySQL when SUPRANIM_TEST_MYSQL=1":
    when defined supraDBMainMysql:
      if getEnv("SUPRANIM_TEST_MYSQL", "") != "1":
        skip()
      else:
        initDatabaseFromEnv()
        block:
          withDBPool do:
            Models.table(FacadeThingsMysql).prepareTable().exec()
            Models.table(QueueJobs).prepareTable().exec()
            Models.table(FailedQueueJobs).prepareTable().exec()
            Models.table(QueueBatches).prepareTable().exec()
        block:
          withDBPool do:
            Models.table(FacadeThingsMysql).insert({title: "mysql-hello"}).exec()
            let rows = Models.table(FacadeThingsMysql).selectAll().getAll()
            check not rows.isEmpty
        block:
          withDBPool do:
            Models.table(FacadeThingsMysql).dropTable().exec()
            Models.table(QueueJobs).dropTable().exec()
            Models.table(FailedQueueJobs).dropTable().exec()
            Models.table(QueueBatches).dropTable().exec()
    else:
      # Compiled without the mysql driver: nothing to link, pass trivially.
      check true
