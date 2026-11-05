#
# Supranim is a high-performance web framework for building
# web applications and microservices in Nim
#
#   (c) 2026 LGPL-v3-or-later License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#

## Unified ORM facade for Supranim applications (backed by Ozark).
##
## Supranim does not fork the ORM: this module re-exports the Ozark
## layers so apps have a single import path:
##
## .. code-block:: nim
##   import supranim/model
##
##   newModel Users:
##     id {.pk.}: Serial
##     email {.unique, notnull.}: Varchar(255)
##
## Drivers (all three supported — pick one per binary):
##
## .. code-block:: nim
##   import ozark/driver/psql   # PostgreSQL, default
##   import ozark/driver/mysql  # MySQL / MariaDB (sqlDriver = 2)
##   import ozark/driver/sqlite # SQLite (file-based, no server)
##
##   initOzarkDatabase("localhost", "mydb", "myuser", "mypassword", Port(5432)) # pg
##   initOzarkDatabase("localhost", "mydb", "myuser", "mypassword", Port(3306)) # mysql
##   initOzarkDatabase("app.db") # sqlite
##
## Prefer `supranim/model/database` in apps: it picks the driver from
## `-d:supraDBMainSqlite` / `-d:supraDBMainMysql` (else postgres) and
## initializes from `DB_TYPE` / `DB_HOST` / `DB_PORT` / `DB_NAME` /
## `DB_USER` / `DB_PASS` / `DB_FILE`, failing fast on mismatch:
##
## .. code-block:: nim
##   import supranim/model/database
##   initDatabaseFromEnv()
##
##   withDBPool do:
##     Models.table(Users).prepareTable().exec()
##
## Migrations (`ozark/migration`, pluginkit-backed, compile-time validated):
##
## .. code-block:: nim
##   # migrations/add_users_20260915120000.nim
##   import app/models
##   import ozark/migration
##
##   newMigration addUsers:
##     up do:
##       Models.table(Users).prepareTable().exec()
##     down do:
##       Models.table(Users).dropTable().exec()
##
## .. code-block:: nim
##   import ozark/driver/sqlite # or psql / mysql
##   import ozark/migration
##
##   initOzarkDatabase("app.db")
##   withDBPool do:
##     migrate("migrations")
##
## Times as Unix epochs (`int8` / `BigInt`) stay portable across all
## three drivers; see `supranim/queue/model` for the canonical example.

import pkg/ozark/model
import pkg/ozark/query
import pkg/ozark/collection
import pkg/ozark/migration

export model
export query
export collection
export migration
