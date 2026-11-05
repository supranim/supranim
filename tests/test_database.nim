#
# Unit tests for supranim/model/database (driver switch + .env init)
#
import std/unittest
import std/os

import supranim/model/database

suite "model/database":
  test "normalizeDbType aliases":
    check normalizeDbType("postgres") == "postgres"
    check normalizeDbType("PostgreSQL") == "postgres"
    check normalizeDbType("pgsql") == "postgres"
    check normalizeDbType("pg") == "postgres"
    check normalizeDbType("mysql") == "mysql"
    check normalizeDbType("MariaDB") == "mysql"
    check normalizeDbType("my") == "mysql"
    check normalizeDbType("sqlite") == "sqlite"
    check normalizeDbType("sqlite3") == "sqlite"
    check normalizeDbType("  MySQL  ") == "mysql"

  test "compiled driver constant matches build":
    when defined supraDBMainMysql:
      check SupranimDbDriver == "mysql"
    elif defined supraDBMainSqlite:
      check SupranimDbDriver == "sqlite"
    else:
      check SupranimDbDriver == "postgres"

  test "dbTypeFromEnv defaults to compiled driver, honors DB_TYPE":
    delEnv("DB_TYPE")
    check dbTypeFromEnv() == SupranimDbDriver
    putEnv("DB_TYPE", "mysql")
    check dbTypeFromEnv() == "mysql"
    putEnv("DB_TYPE", "PostgreSQL")
    check dbTypeFromEnv() == "postgres"
    delEnv("DB_TYPE")

  test "initDatabaseFromEnv raises on driver mismatch":
    # Default test build compiles the postgres driver, so asking for
    # mysql must fail fast instead of generating pg SQL for MySQL.
    when not defined supraDBMainMysql:
      putEnv("DB_TYPE", "mysql")
      expect DbConfigError:
        initDatabaseFromEnv()
      delEnv("DB_TYPE")
    when not defined supraDBMainSqlite:
      putEnv("DB_TYPE", "sqlite")
      expect DbConfigError:
        initDatabaseFromEnv()
      delEnv("DB_TYPE")

  test "invalid DB_PORT raises DbConfigError":
    when defined supraDBMainSqlite:
      # sqlite ignores DB_PORT; nothing to validate
      discard
    else:
      putEnv("DB_TYPE", SupranimDbDriver)
      putEnv("DB_PORT", "not-a-port")
      expect DbConfigError:
        initDatabaseFromEnv()
      delEnv("DB_PORT")
      delEnv("DB_TYPE")
