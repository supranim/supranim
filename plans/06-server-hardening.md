# 06 — Server hardening (implemented)

## Fixes

### Service error semantics (`core/services.nim` `onRequestHandle` quote)
- Unknown path: `501 Not Implemented` → `404` with the service JSON
  error shape (`newErrorResponse(404, "Not found")`). Nothing depended
  on `501` (repo-wide grep: only middleware/afterware whitelists).
- Middleware short-circuit (`else: discard # todo`, silent drop) →
  `403` with `getDefault(Http403)` (both names in scope in the quote:
  `response` is imported, `httpcore` is imported).
- Note: service *codegen* is only macro-definition-checked here. No
  `WebService` compiles today for an unrelated pre-existing reason
  (`initRouter` `nil`-for-`string`, plus `index`/`routerInstance` syms
  with no routes); see follow-ups.

### Fileserver (`core/fileserver.nim`)
- `isTraversalPath`: any `..` segment (post-`normalizedPath`) → treated
  as not-found, never reaches the filesystem. Applied in all disk
  procs; `bool`/`foundRes` overloads return false (fall through to the
  app 404 handler), direct-send overloads answer `404`.
- `mimeFor`: dot/dotless/empty-safe (the old `ext[1..^1]` raised
  `IndexDefect` on extensionless files).
- `fileETag` (size+mtime hex), `httpDate`, `setStaticCacheHeaders`
  (`ETag` + `Last-Modified` + `Cache-Control: public, max-age=86400` +
  `Accept-Ranges: bytes`), `notModified` (`If-None-Match`/`*`, pure).
- Disk sends: conditional → `304`, valid `Range` → `206` via `streamFile`
  (validated with `parseRangeHeader`; unsatisfiable → `416` with
  `Content-Range: bytes */N`), else `sendFile`.
- `sendDownloadable`: traversal/missing → `404` (was: no response at
  all), plus `ETag` + `private` cache + `Accept-Ranges` + `304` support.

### Server lifecycle (`network/webserver.nim`, `src/supranim.nim`)
- New `WebServer.stop()`: stops the multi-threaded pool server when
  present, else the single server; nil-safe and idempotent. No automatic
  signal handlers (deliberate — hosts keep control); call it from your
  own `SIGINT`/`SIGTERM` handler, timer, or request handler.
- `srvThreads` clamped to `<= 256` (`<= 0` still means "let `start`
  pick `countProcessors()`); a config typo can no longer spawn
  thousands of workers.
- Non-GET dispatch now mirrors GET: `supraMicroservice` callbacks
  actually run (`req.addr, res.addr` — previously skipped entirely,
  falling through to a `500`), all variants wrapped in `try/except →
  500`, `isStreaming` honored, `res.getHeaders()` normalized.

## Tests
- `tests/test_fileserver.nim` (13 tests): pure unit (`isTraversalPath`,
  `mimeFor`, `fileETag`, `httpDate`, `notModified`, cache headers,
  bool-overload traversal rejection, fresh-server `stop()` no-op) plus
  fork-based live integration (same pattern as `test_server_integration`):
  `200` + body + `ETag`/`Cache-Control`/`Accept-Ranges`/`Last-Modified`,
  `If-None-Match → 304`, `Range bytes=0-3 → 206` + prefix, traversal →
  `404`, `sendAssetFile` fixed-file path + ETag.
- Full suite: 29/29 pass via `clue test`.

## Follow-ups (not in this task)
- Service-macro repair: no `WebService` compiles (`initRouter` `nil`
  for `string` at `services_web.nim(17,9)`; bare `initService` fails on
  undeclared `IndexRoute_*`). Blocks verifying service codegen paths
  and examples end-to-end.
- `HttpService.private/privateKey` + `HttpServiceIndex.authorization`
  are still declared-but-never-enforced; design: `private`/`privateKey`
  service fields + `x-api-key` check in `onRequestHandle` (do after the
  macro repair so the `401` path is compilable/testable).
- No TLS/HTTP2/compression (powpow limitation); `releaseUnusedMemory`
  stays opt-in (per-request `malloc_trim` would cost more than it saves).
