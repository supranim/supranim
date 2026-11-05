# 02 — Router hardening (implemented)

## Fixes

### `core/autolink.nim`
- `autolinkController` now bounds-checks every `{...}` parse step.
  Missing `}`, missing `:`, missing regex, or dangling `?` raise
  `ValueError("... in \"<path>\"")` instead of `IndexDefect`.
  Covers `/a/{b:id`, `/a/{`, `/a/{b`, `/a/{b:`, `/a/{b:id?x`, etc.
- `tests/test_autolink.nim`: `IndexDefect` expectation replaced with `ValueError`.

### `core/response.nim`
- Removed unused `HeaderHttpRedirect`, unused `bodyLen` local.
- `getDefault(code)`: every 400/401/403/404/405/500/502/503 returns a
  minimal HTML page; fallback generic page for other codes (never `""`).
  Fixes 403 discarding HTML (`return "Forbidden"`) and `Http500 == ""`.
- `redirect301(target)`: implemented (`Location` + `Http301` + `return`),
  was a no-op.
- `tests/test_response.nim`: updated `getDefault` assertions to `in` checks.

### `core/router.nim`
- `newHttpRoute` single overload: fully initializes `httpRouteType`,
  compiles `prog`/`jit` only when regex non-empty (fixes
  `OpenParserRegexError: Empty expression` for error routes which use `""`).
- `registerRoute`: keeps first-wins (test-locked), added `hasRoute`,
  `replaceRoute` (explicit overwrite), `unregisterWsRoute`.
  `unregisterRoute` still handles 9 methods; ws/errors via new helpers.
- `getMiddlewares`/`getAfterwares`: public, guarded by
  `hasMiddleware`/`hasAfterware` (no `FieldError`); empty case relies on
  Nim default empty seq (no explicit `@[]`).
- `resolveMiddleware`/`resolveAfterware`: out-of-range index returns
  `Http204` instead of `IndexDefect`. `resolveAfterware` empty now
  returns `Http204` (was `Http202`, return value is discarded in `supranim.nim`).
- Error handlers: `errorHandler` stores specific `"404"`/`"500"` keys plus
  generic `"4xx"`/`"5xx"` fallback (first generic wins). Added
  `hasErrorHandler`, `callError(code)` (specific then generic, returns bool),
  `call5xx`. `call4xx`/`call5xx`/`callError` never raise `KeyError`.
- `checkExists`: `HEAD` falls back to `GET` (exact + dynamic) when no
  explicit `HEAD` route.
- Added `allowedMethods(path)` (single lock, exact + dynamic per method)
  and `isMethodNotAllowed(path, method)` for `405` vs `404` decisions.
  `HEAD` never 405 when `GET` exists.
- Removed unused `sequtils` import.

## Tests
- Updated: `test_autolink`, `test_response`, `test_router` (afterware 204).
- New: `tests/test_router_hardening.nim` (12 tests): specific/generic error
  slots, safe no-op calls, `hasRoute`/`replaceRoute`/`unregisterWsRoute`,
  HEAD fallback, `allowedMethods`/`isMethodNotAllowed` incl. dynamic,
  middleware/afterware index guards, empty getters.
- Full suite: 23/23 pass via `clue test`.
