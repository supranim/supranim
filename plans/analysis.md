# Supranim — Current Implementation Analysis & Gaps

Date: 2026-11-05
Version: v0.1.13 (`supranim.nimble`)
Entry: `src/supranim.nim:1-241`

## 1. Routing / Request / Response — mostly functional

Works:
- `src/supranim/core/router.nim:78-82,213-382` 9 verbs + `ws`, `routes:` macro with `group`, multi-verb `(get,post)->`, per-route middleware pragmas.
- Params `src/supranim/core/autolink.nim:32-44` `{name:slug|id|uuid|any|...}`, optional `{x:?}`.
- Middleware `src/supranim/middleware.nim:28-67`, `src/supranim/afterware.nim:22-33`, `src/supranim.nim:41-59,104-146` — `next/fail/abort`, base + route + afterware chain.

Gaps:
- `src/supranim/core/response.nim:53-59` — `getDefault` only `403/404`, `Http403` discards HTML, `Http500==""`.
- `src/supranim/core/response.nim:107-110` — `redirect301` no-op, `HeaderHttpRedirect` unused.
- `src/supranim/core/router.nim:808-831` — single `4xx` slot, `400/404` only, `KeyError` if `initRouterErrorHandlers` missed, no `5xx`.
- Duplicate route silently ignored (`router.nim:227`).
- `unregisterRoute` no `ws/errors` branch, `GC_ref` leak (`router.nim:141-156,272-309`).
- Linear scan, no static-over-dynamic priority, no `405`, no `HEAD->GET`.
- `src/supranim/controller.nim:52-89` — `getFieldsJson/getBodyDataJson` stubs (`discard`), `getSomeBodyData:67` `UnpackDefect` on empty body, `getBodyData[JsonNode]:105` raises on missing/invalid JSON.
- `src/supranim/core/autolink.nim` — unclosed `{` → `IndexDefect` not `ValueError` (pinned in `tests/test_autolink.nim:61`).
- `request.nim:119` `getPlatform` never returns `none` (masks missing header).

## 2. App bootstrap / Config / Services / Server

Works:
- Singleton `Application` (`core/application.nim`), `init(app)`, `initApp`, `cli`, `services`, auto-discovery `routes.nim/controllers/middlewares/listeners`.
- Multi-format config `yml/yaml/toml/json` (`core/config.nim`), `.env` + `.env.production` overlay, `embedConfigs/staticConfig[T]()`.
- `ServiceType: Global|Singleton|Thread|ThreadPool|Web|UnixService` (`core/services.nim`), `fileserver.nim` + `withAssetsHandler`, `powpow` single/multi/unix start.

Gaps:
- `core/application.nim:113` TODO rename, `port/address` never assigned, `supraWebkit:90` `discard # todo`.
- No graceful shutdown, `ThreadService.stop` blocking poison-pill, `Chan` never closed.
- `WebService onRequestHandle` returns `501` not `404`, ignores afterware errors, `private/privateKey/ApiKey` never enforced.
- `GET` vs non-`GET` asymmetry in `src/supranim.nim:109-144`.
- Dead: `initChannelRouter`, `extractThreadServicesBackend/Client`, `microservice.nim` pure re-export.
- Config `put*` top-level only, no env interpolation, no deep set.
- Fileserver: no range/etag/cache/traversal guard beyond `normalizedPath`.

## 3. Model / ORM (`src/supranim/model.nim:13`)

- Pure `export pkg/ozark/model`. No native code.
- Via `ozark-0.2.0`: `psql+sqlite` exist (README stale: claims PG only + plans MySQL/SQLite), no MySQL driver, `where` only `=/!=`, `UPDATE` workaround via raw SQL in `service/queue_work.nim:33-42`, migrations in ozark but unwrapped/undocumented.

## 4. Auth / Session / Cookie / Validation

- Cookies solid: `support/cookie.nim` serializer, `secure/auto/proxy` + tests.
- Auth thin: `support/auth.nim` only `nimcypher` primitives (`box/sign/seal/token`), no password/JWT/RBAC/OAuth. `nimcypher/password.nim` Argon2id `hashPassword/verifyPassword` exists but unwrapped.
- Sessions missing: only `controller.nim:208-219` `isAuth` referencing non-existent `UserSessions` model (single grep hit, `withDBPool/Models` not imported — broken template). No store/create/rotate/expiry/GC, no `config/session.yml`. Reference impl exists out-of-tree: `supranim-packages/supranim-session` (`HttpSession` Singleton, in-memory + DB, CSRF, flash, `session.yml`).
- Validation missing: no form/request validator. Only `support/scanner.nim` regex `isEmail/isUUID/...`. `controller.getFields*` stubs. `bag/withValidator` lives out-of-tree (`packages/bag`), `valido` comprehensive but not in `supranim.nimble` requires.

## 5. Queue / Cache / Storage / Events / Logger

- Queue minimal but tested: `service/queue.nim` DB-backed `dispatch`, `service/queue_work.nim` `startQueueWorker` polling — at-least-once, one worker/queue, `timeout` advisory.
- Cache: `service/cacheable.nim` Boogie disk KV microservice, not HTTP response cache / Redis.
- Storage: `service/storage.nim` `flysystem` local drivers only, cloud claimed but absent.
- Events: `service/events.nim` `emitter` re-export, works.
- Logger: `support/logit.nim` + `service/logger.nim`, works.

## 6. Network / Support / Tests / Deps / Docs

- `network/webserver.nim:513` sole `powpow` backend — `addHeader/removeHeader/startChunk/sendChunk` intentional no-ops, `addEvent` 30ms shim no-op multi-threaded.
- `network/websocket.nim:29` pure re-export, no rooms/pub-sub/auth, only example `examples/services_ws.nim`.
- `support/url.nim`, `qr.nim` zero tests; `scanner.nim:181` `isMainModule` demo references undefined `input`; ~10 pattern consts + `captures()` untested; `logit` console/header/exitOnError untested.
- `docs/` empty, README points to external docs, `supranim.nimble` no `test` task, `clue.lock` untracked + stale `openparser` constraint, many `develop` path deps, `examples/webapp_example` binary untracked, smoke test requires `supra`+network+PG + fixed ports.

## Prioritized roadmap

1. Sessions/auth + validation (this task)
2. Router hardening + autolink `ValueError`
3. ORM wrapping + MySQL/migrations docs
4. WebSocket framework + templating parity
5. Graceful shutdown/TLS/caching headers
6. Docs/tests/deps hygiene
