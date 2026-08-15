# Plan: Extensive unit test suite for Supranim (powpow backend + internal modules)

Status: **deferred** — saved for later implementation. No tests are to be written yet.

## 1. Goals

1. **powpow backend** (`network/backends/webserver_powpow.nim`) — parse/route helpers in isolation, plus a live HTTP server integration harness (in-process thread server + `std/httpclient`).
2. **Internal modules** — `core/` (router, autolink, response, application, paths), `support/` (uuid, nanoid, slug, cookie, scanner, http, logit), `service/` (assets).
3. **Full-app smoke test** — `supra init` starterkit app booted end-to-end against local source with embedded Postgres (`pkg/greskewel`), probed over real HTTP.

## 2. Test infrastructure

**`tests/config.nims`** (adds to existing path switch):
```nim
import unittest
switch("path", "$projectDir/../src")
switch("define", "features.supranim.powpow")
switch("threads", "on")
```
This makes plain `nimble test` compile every `tests/t*.nim` with the powpow backend and thread support.

**`supranim.nimble`** — one addition so the smoke test can `import pkg/greskewel` (top-level/dev only):
```nim
dev "greskewel >= 0.1.1"
```
(`dev` deps are resolved only when supranim is the top-level project — i.e. `nimble test`/`nimble install` in this repo — not for consumers. Add alongside the existing `feature` blocks; keep the `feature "powpow"` requires as-is. `testRequires` is NOT usable: the nimble v2 declarative parser rejects it.)

**`tests/helpers.nim`** (name must NOT start with `t` so `nimble test` won't auto-run it — `testhelpers.nim` would be picked up): `getFreePort()` (bind `Port(0)`, read local addr, close), `waitForTcp(port, retries)` readiness poll, `tempDir()`/cleanup, and a tiny `httpGet/httpPost` wrapper over `std/httpclient`.

**Delete** stale `tests/test1.nim`.

**Running:** `nimble test` (needs all deps + `supra` CLI + network for the smoke test). Files run independently; each pulls the framework, so expect minutes of compile time. Optional later optimization: a single `t_all.nim` aggregator.

## 3. Unit test matrix

| File | Module under test | Coverage |
|---|---|---|
| `t_autolink.nim` | `core/autolink` `autolinkController` | Static→controller-name mapping (`/users`→`getUsers`, `/`→`getHomepage`), dynamic params (`/electronics/{category:id}`→`getElectronicsCategory`, `id`→`[0-9]+`), optional params (`?` suffix → wrapped `(...)?` + `isOptional` flag), regex path escaping (`/`, `-`, `+`), websocket prefix (`ws`), `params.isSome`, and error cases (missing `}`, unknown pattern name, optional-without-`}` → `ValueError`). |
| `t_router.nim` | `core/router` | `newHttpRouter` table init; `registerRoute` static + dynamic; `checkExists` exact/dynamic/no-match (verify captured params); `checkWsExists`; duplicate registration no-overwrite; `resolveMiddleware` (none→`Http204`, chain order via side-effect counter, `Http302` short-circuit, index increment); `resolveAfterware` (none→`Http202`, chaining); `errorHandler`/`call4xx`; middleware+afterware arrays on routes. Uses `default(Request)` for req/res. |
| `t_response.nim` | `core/response` | `getDefault` (`Http403`→`"Forbidden"`, `Http404`→html, other→`""`); `toString` header formatting; `addHeader`/`getHeaders`/`setCode`/`getCode`/`setBody`/`getBody`; `json`/`respond`/`redirect` templates via helper proc with `default(Request)` + `Response` (verifies code, Content-Type, body). |
| `t_application.nim` | `core/application` | `initApplication`/`appInstance`/`AppInstance` (non-nil, idempotent); `paths()`/`getPort`/`getUuid`/`getAddress`; `config("x.y")` nil for unknown; **macro pipeline**: define controllers via `newController`, declare `routes:`, call `initHttpRouter()` (with a local `get4xx` — `initHttpRouter`/`initRouterErrorHandlers` reference it), assert `App.router.checkExists` matches and `httpErrors["4xx"]` registered. |
| `t_paths.nim` | `core/paths` | `ApplicationPaths.init` (createDirs on/off, `expandTilde`/`expandFilename`), `getInstallationPath`, `resolve(dir,file)`, `staticStorage`, `p` template, constants non-empty; temp-dir cleanup. |
| `t_uuid.nim` | `support/uuid` | `uuid4()` version=4/variant=RFC4122/length; parse from `8-4-4-4-12` and 32-hex (any case); `$` round-trip; `$$` no-hyphen; `hexify`; errors on bad length/hex. |
| `t_nanoid.nim` | `support/nanoid` | default length/alphabet-valid; custom alphabet/size; size≥1 & alphabet non-empty guards; determinism of charset only. |
| `t_slug.nim` | `support/slug` | whitespace→`-`, punctuation, leading/trailing, `allowSlash`, lowercase, unicode transliteration (`unidecode`), `generate` alias. |
| `t_cookie.nim` | `support/cookie` | `$` output (name=value, HttpOnly, Expires, Max-Age, Domain, Path, Secure, SameSite order); `newCookie` defaults; `parseCookies` (empty→nil, multi-cookie, expiry set); `isExpired`; `expires()` pushes to past. |
| `t_scanner.nim` | `support/scanner` | `isEmail/isSlug/isIPv4/isURL/isDate/isUUID/isJWT/isE164` etc.; `scanFind`/`scanAll`/captures; reusable `newScanner`. |
| `t_http_support.nim` | `support/http` | `normalizePath` collapse (`//foo//bar→/foo/bar`), empty, no-slash cases. |
| `t_logit.nim` | `support/logit` | `initLogit` to temp dir; `start`/`log`→file contents; `header`; `finish`; `$LogLevel`; invalid folder→`IOError`. |
| `t_assets.nim` | `service/assets` | `staticAssets()` singleton; `addAsset/get/hasAsset`; `addTextFile/directory/getFile/hasFile`; `listAssetsDir` prefix filter; duplicate/not-found `StaticAssetsError`. |
| `t_webserver_powpow.nim` | `network/backends/webserver_powpow` (pure part) | `parseRangeHeader` (`bytes=a-b`, `bytes=a-`, start<0, finish≥fileSize, finish<start, non-`bytes=`, garbage→`none`); `newWebServer(port)`/`(port, multiThread)` defaults; `addCallback`/`registerCallback`/`unregisterCallback` normalization + idempotent delete on unstarted server. |

## 4. Powpow backend live integration — `t_server_integration.nim`

In-process thread server + `std/httpclient` against a free port:

- `WebServer` started in a `{.thread.}`; `onRequest` mirrors the supranim pipeline (`checkExists` → `resolveMiddleware` → callback → `resolveAfterware` → `resp`) so it exercises the **real backend + router end-to-end**.
- Cases: static route 200 + body; dynamic route param echo; query parsing (`getQuery`); POST body/form decode (`getBody`, `decodeQuery`); JSON response (Content-Type + body via `json` template); redirect (Location header, 302/303); middleware fail→403; afterware response mutation; 404 path (router miss + `call4xx`); custom/echo headers; cookie round-trip via `parseCookies`; double-`send` guard (`responseSent`); `addCallback` low-level path short-circuiting the router; `sendFile`/`streamFile` on a temp file incl. `Range: bytes=…`→206.

## 5. Full-app smoke test — `t_smoke_app.nim` (supra + greskewel)

1. Assert `supra` CLI present (fail if missing — per "always run" decision).
2. **Embedded Postgres**: temp `basePath`; `greskewel` → `downloadBinaries` (cached, first run downloads from Maven Central) → `init` (initdb) → `start` on a free port. (Import-time `staticExec` risk in `status` — see Risks.)
3. `supra init testapp --skipconfig --nocache` in a temp work dir (downloads starterkit zip).
4. Overwrite generated `.env.yml` `database.local` with embedded PG creds (`postgres`/`postgres`/`postgres`/`<pgPort>`).
5. **Use local supranim**: `nimble develop --path:<this repo>` (or hand-written `nimble.paths` mirroring the repo's) so `import pkg/supranim` resolves to local `src`.
6. **Force powpow**: replace `--define:supraNative` with `--define:features.supranim.powpow` in `src/app.nims` (`supraNative` is dead code — no references in `src/`; the code gates on `features.supranim.powpow`).
7. `nimble build` → assert exit 0 and `build/testapp` exists.
8. Boot `./build/testapp start <existingDir>` as subprocess (existing dir so `initStartCommand` succeeds); poll TCP until ready.
9. Probe: `GET /` and `/auth/login` (starterkit non-DB routes) → status ∈ {200, 302}; assert body non-empty; confirm routing/rendering pipeline works.
10. Cleanup: kill subprocess; `greskewel.stop()`/`dispose()`; remove temp dirs.

## 6. Out of scope / deferred

- `support/filesystem` + `service/storage` — deferred to the `pkg/flysystem` migration.
- `service/events` (spawns threads/writes logs), `service/cacheable` (WebService, main-module-only), `service/logger` service (only `support/logit` unit-tested), `support/httpclient`, `support/openmp`, `support/qr`, `nghttp2`, libevent backend, WebSockets.
- Full `t_*`-per-file is acceptable; if too slow, collapse suites into one `t_all.nim` aggregator later.

## 7. Risks & mitigations

1. **greskewel `staticExec` at compile time** (`status` proc): verify `import pkg/greskewel` compiles in a scratch file early in implementation. If it fails, fall back to a small inline bootstrap (curl jar → unzip → tar → `initdb` → `pg_ctl start`) in the test.
2. **Starterkit boot fragility**: `db.init()`/`tim.init()`/sessions need embedded PG up + correct `.env.yml`; probe only non-DB routes and accept `{200,302}`. If tim/sessions block boot, temporarily neutralize their service calls in the generated `app.nim` (documented fallback).
3. **Thread-safety**: `--threads:on` in `tests/config.nims`; greskewel uses a module-global channel (one instance per process — fine). Server thread killed at process exit.
4. **Smoke test cost**: first PG binary download + full app build add minutes to `nimble test`; unavoidable per "always run" decision.
5. **Port collisions**: `getFreePort()` per server; retry-connect readiness polling.

## 8. Implementation order

1. `tests/config.nims` + `tests/helpers.nim`; delete `test1.nim`.
2. Pure unit tests (autolink, router, response, paths, uuid, nanoid, slug, cookie, scanner, http, logit) — fastest feedback.
3. `t_webserver_powpow.nim` (pure powpow helpers).
4. `t_application.nim` (macro pipeline; needs local `get4xx`).
5. `t_server_integration.nim` (thread server + HTTP).
6. `dev "greskewel >= 0.1.1"` in nimble; verify greskewel imports; `t_smoke_app.nim`.
7. Run `nimble test`; iterate on failures.

## 9. CI

Extend `.github/workflows/test.yml`: after the existing install/build steps, add `- run: nimble test` (covers unit + integration + supra smoke; greskewel resolves via the new `dev` dep and is installed by the existing `nimble install -Y`). Smoke test needs network on `ubuntu-latest`/`macos-latest` (already required for the starterkit download).

## Key facts discovered during planning

- `nimble test` runs only `tests/t*.nim` (top level, no subdirs) with `-r --path:.`; `tests/config.nims` is auto-loaded per-file.
- `-d:features.supranim.powpow` is the nimble-standard define for the powpow feature (`build.nim` passes `features.<pkg>.<feature>` for CLI-enabled features).
- The `Request` type's `powReq`/`powRes` fields are private, but `default(Request)` works for pure router/middleware/response tests.
- powpow's `HttpParser`/`HttpRequest` can be built in-memory, but supranim's `Request`/`send` require a real `HttpResponse` — hence live server integration tests for the backend.
- The starterkit `src/app.nims` sets `--define:supraNative` which is dead code; must be replaced by `--define:features.supranim.powpow` to exercise powpow.
- `greskewel-0.1.1` is already installed and provides embedded Postgres (`postgresql://postgres:postgres@localhost:<port>/postgres`).
- nimble v2 declarative parser supports `dev "pkg"` (top-level-only deps) but rejects `testRequires`.
