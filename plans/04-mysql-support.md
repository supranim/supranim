# 04 — MySQL support end-to-end (supranim + ozark + starter)

## Problem
- Ozark already shipped `driver/mysql.nim` (`sqlDriver = 2`), but Supranim
  docs/tests assumed pg-or-sqlite only.
- Queue tables use `int8` Unix epochs; `ozark/query.nim:prepareTable`
  mapped `serial/bigserial/smallserial/money/boolean/timestamptz` for MySQL
  but left `int8/int4/int2/float8/float4` as raw PG names → `CREATE TABLE`
  would fail on MySQL (`int8` is not a MySQL type).
- Starter `.env` parsing ignored `DB_TYPE`/`DB_PORT` and had no mysql branch:
  `db.nim` (`when sqlite … else psql`), 3 more files with the same 2-way
  fallback, `.env.sample`/`.env.yml` mentioning only sqlite/postgres.

## Changes

### Ozark (`../ozark/src/ozark/query.nim`) — type mapping
Added MySQL column mappings in `prepareTable`:
`int8→bigint`, `int4→int`, `int2→smallint`, `float8→double`, `float4→float`.
Follows the existing `serial→int + AUTO_INCREMENT` style. `nim check` clean.

### Supranim core
- New `src/supranim/model/database.nim`: single import for apps.
  `-d:supraDBMainSqlite` → sqlite, `-d:supraDBMainMysql` → mysql,
  else postgres. Exports the driver plus:
  `normalizeDbType` (`postgresql/pgsql/pg→postgres`, `mariadb/my→mysql`,
  `sqlite3→sqlite`), `dbTypeFromEnv`, `envOr` (blank counts as unset),
  `initDatabaseFromEnv(poolSize=10)` — reads `DB_TYPE/HOST/PORT/NAME/USER/PASS/FILE`,
  raises `DbConfigError` on `DB_TYPE` vs binary mismatch or bad `DB_PORT`.
  `nim check` clean for default, `supraDBMainSqlite`, and `supraDBMainMysql`.
- `src/supranim/model.nim` docs: point to `model/database` + `initDatabaseFromEnv()`.
- `tests/test_database.nim` (5 tests): alias normalization, compiled-driver
  constant, `DB_TYPE` honoring, mismatch `DbConfigError`, bad-port error.
- `tests/test_mysql_integration.nim` (opt-in): compiles without mysql libs
  by default (trivial pass). With `-d:supraDBMainMysql` + libs + server
  (`SUPRANIM_TEST_MYSQL=1`, `DB_HOST/PORT/NAME/USER/PASS`) it round-trips
  `facade_things_mysql` + all three queue tables (proves `int8→bigint`).

### Starter template (`../supranim-packages/supranim-starter`)
- `src/service/provider/db.nim`: replaced 2-way import + manual
  `getEnv` init (which ignored `DB_PORT`) with `import supranim/model/database`
  + `initDatabaseFromEnv()`. Table creation/seeding unchanged.
- `src/controller/account.nim`, `src/controller/auth.nim`,
  `src/service/event/listeners/account.nim`: 2-way import → 3-way
  (`mysql` / `sqlite` / `psql`).
- `.env.sample`: `DB_TYPE` documented as `sqlite|postgres|mysql` with
  matching define + port per backend, added `DB_FILE=app.db`.
- `.env.yml`: `type: postgres # either sqlite or postgres` →
  `# sqlite | postgres | mysql (must match the compiled driver)`.

## Verification
- `clue test` in supranim: 26/26 pass (24 existing + `test_database` +
  `test_mysql_integration` skip-path).
- `nim check` clean: `model/database.nim` (all three defines), `ozark/query.nim`.
- Live MySQL round-trip not run here (no server/libs); run the opt-in test
  per its header when a server is available.
