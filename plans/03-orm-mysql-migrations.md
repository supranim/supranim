# 03 — ORM parity: MySQL + migrations (implemented)

Confirmed: Ozark ships `driver/mysql.nim` + `mysql_runtime.nim`
(`sqlDriver = 2`), alongside `psql` (1) and `sqlite` (3).
Ozark README already lists all three. Supranim was stale.

## Changes

### `src/supranim/model.nim` — unified facade (was pure `export model`)
- Now re-exports `model` + `query` + `collection` + `migration`
  so apps have one import: `import supranim/model`.
- Header docs: all three drivers with `initOzarkDatabase` examples
  (pg `:5432`, mysql `:3306`, sqlite file), plus `newMigration` /
  `migrate("migrations")` pluginkit flow and Unix-epoch `int8` portability note.
- Verified: `clue check` clean for `model.nim` + `queue/model.nim`.

### Driver-agnostic docs
- `src/supranim/queue/model.nim`: `psql and sqlite` → `psql, mysql and sqlite`.
- `src/supranim/service/queue.nim`: driver import docs `psql or sqlite`
  → `psql, mysql or sqlite` (+ example comment).
- `src/supranim/service/queue_work.nim`: same, `sqlite` example →
  `sqlite # or psql / mysql`.

### `README.md`
- `Built-in ORM supporting PostgreSQL (with plans for MySQL and SQLite)`
  → `Built-in ORM supporting PostgreSQL, MySQL and SQLite (via Ozark)`.

## Tests
- New `tests/test_model.nim` (5 tests): `getTableName` snake_case,
  migration driver ids 1/2/3, sqlite round-trip via facade
  (`prepareTable`/`insert`/`selectAll`, temp DB, pool 2), queue model
  table names, `compiles(initOzarkDatabase/withDBPool)` API check.
- Avoided importing `driver/mysql` in tests (needs libmysqlclient at link);
  MySQL covered via `OzarkMigrationDriverMysql == 2` + source presence
  in Ozark, plus facade docs.
- Full suite: 24/24 pass via `clue test`.
