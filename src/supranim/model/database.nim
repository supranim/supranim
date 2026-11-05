#
# Supranim is a high-performance web framework for building
# web applications and microservices in Nim
#
#   (c) 2026 LGPL-v3-or-later License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#

## Unified database driver import + `.env`-based initialization.
##
## Import this module instead of an Ozark driver directly:
##
## .. code-block:: nim
##   import supranim/model/database
##
## Compile-time driver selection (one driver per binary):
##
## - `-d:supraDBMainSqlite` → `ozark/driver/sqlite` (file-based, no server)
## - `-d:supraDBMainMysql`  → `ozark/driver/mysql` (MySQL / MariaDB)
## - default                → `ozark/driver/psql` (PostgreSQL)
##
## Then initialize from the environment (dotenv `.env`, shell, or platform):
##
## .. code-block:: nim
##   initDatabaseFromEnv() # poolSize = 10 by default
##
## Recognized variables (all optional, sensible defaults):
##
## - `DB_TYPE`: `sqlite` | `postgres` (`postgresql`, `pgsql`, `pg` aliases)
##   | `mysql` (`mariadb`, `my` aliases). Defaults to the compiled driver.
##   A mismatch between `DB_TYPE` and the compiled driver raises `DbConfigError`.
## - sqlite: `DB_FILE` (alias `DB_NAME`, default `app.db`).
## - postgres/mysql: `DB_HOST` (default `localhost`), `DB_PORT`
##   (default `5432` / `3306`), `DB_NAME`, `DB_USER`, `DB_PASS`
##   (defaults `""`, same as the starter template).
##
## The starter template (`supranim-starter`) reads the same variables in
## `src/service/provider/db.nim`; new apps should call this helper instead
## of copy-pasting `when defined supraDBMainSqlite` branches.

import std/[os, strutils]

when defined supraDBMainMysql:
  import pkg/ozark/driver/mysql
  export mysql
  const SupranimDbDriver* = "mysql"
    ## Driver baked into this binary (`mysql`).
elif defined supraDBMainSqlite:
  import pkg/ozark/driver/sqlite
  export sqlite
  const SupranimDbDriver* = "sqlite"
    ## Driver baked into this binary (`sqlite`).
else:
  import pkg/ozark/driver/psql
  export psql
  const SupranimDbDriver* = "postgres"
    ## Driver baked into this binary (`postgres`).

type
  DbConfigError* = object of CatchableError
    ## Raised when `DB_TYPE` disagrees with the compiled driver or when
    ## a port / pool size cannot be parsed.

proc normalizeDbType*(s: string): string =
  ## Normalizes `DB_TYPE` values to `sqlite` | `postgres` | `mysql`.
  ## Unknown values are returned lower-cased and stripped as-is.
  let v = s.strip().toLowerAscii()
  case v
  of "postgresql", "pgsql", "pg", "postgres": "postgres"
  of "mariadb", "my", "mysql": "mysql"
  of "sqlite", "sqlite3": "sqlite"
  else: v

proc dbTypeFromEnv*(defaultType = SupranimDbDriver): string =
  ## Reads `DB_TYPE` from the environment (never from a default file),
  ## normalized via `normalizeDbType`. Falls back to `defaultType`
  ## (the compiled driver) when unset or blank.
  let raw = getEnv("DB_TYPE", "").strip()
  if raw.len == 0:
    return normalizeDbType(defaultType)
  normalizeDbType(raw)

proc envOr*(key, default: string): string =
  ## `getEnv(key, default)` that also falls back when the variable is
  ## present but blank (common in `.env.sample` templates).
  result = getEnv(key, default)
  if result.strip().len == 0:
    result = default

proc initDatabaseFromEnv*(poolSize = 10) =
  ## Initializes Ozark from `DB_*` environment variables and opens a pool.
  ## Raises `DbConfigError` when `DB_TYPE` does not match the driver this
  ## binary was compiled with — the driver is a compile-time choice
  ## (`-d:supraDBMainSqlite` / `-d:supraDBMainMysql`, else postgres),
  ## so a runtime mismatch would generate SQL for the wrong backend.
  let dbType = dbTypeFromEnv()
  if dbType != SupranimDbDriver:
    raise newException(DbConfigError,
      "DB_TYPE `" & dbType & "` does not match the compiled driver `" &
      SupranimDbDriver & "`. Rebuild with " &
      (case dbType
       of "sqlite": "`-d:supraDBMainSqlite`"
       of "mysql": "`-d:supraDBMainMysql`"
       else: "no driver define (postgres is the default)") &
      " or fix `DB_TYPE`.")
  when defined supraDBMainSqlite:
    let file = block:
      let f = getEnv("DB_FILE", "").strip()
      if f.len > 0: f
      else:
        let n = getEnv("DB_NAME", "").strip()
        if n.len > 0: n else: "app.db"
    initOzarkDatabase(file)
    initOzarkPool(poolSize)
  elif defined supraDBMainMysql:
    let
      host = envOr("DB_HOST", "localhost")
      portRaw = envOr("DB_PORT", "3306").strip()
      name = getEnv("DB_NAME", "")
      user = getEnv("DB_USER", "")
      pass = getEnv("DB_PASS", "")
    var portNum = 3306
    try:
      portNum = parseInt(portRaw)
    except ValueError:
      raise newException(DbConfigError,
        "Invalid DB_PORT `" & portRaw & "`: expected an integer.")
    initOzarkDatabase(host, name, user, pass, Port(portNum))
    initOzarkPool(poolSize)
  else:
    let
      host = envOr("DB_HOST", "localhost")
      portRaw = envOr("DB_PORT", "5432").strip()
      name = getEnv("DB_NAME", "")
      user = getEnv("DB_USER", "")
      pass = getEnv("DB_PASS", "")
    var portNum = 5432
    try:
      portNum = parseInt(portRaw)
    except ValueError:
      raise newException(DbConfigError,
        "Invalid DB_PORT `" & portRaw & "`: expected an integer.")
    initOzarkDatabase(host, name, user, pass, Port(portNum))
    initOzarkPool(poolSize)
