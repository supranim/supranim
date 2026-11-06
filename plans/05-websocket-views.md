# 05 — WebSocket rooms + HTML views (implemented)

## Gaps closed
- `network/websocket.nim` was a pure re-export: no rooms, pub-sub,
  auth, or upgrade helper. App code fell back to low-level
  `registerCallback` + manual `websocketUpgrade` (see `initApp` docs).
- No view layer: README claimed a templating engine, but core only had
  `getDefaultPage` + `json`/`respond` templates. Full Tim engine lives
  in the starter (`tim.nim` service), not in core.

## Changes (no new nimble deps)

### `src/supranim/support/ws.nim` (new)
- `WsHub`: named rooms (`room -> pointer -> WsConnection`), `RwLock`-guarded.
  `newWsHub`, `defaultHub`/`setDefaultHub` (lock-guarded globals with
  `gcsafe` assertions, same pattern as `session.defaultStoreInit`).
- `joinRoom` (idempotent, nil-safe), `leaveRoom` (drops empty rooms),
  `leaveAllRooms` (call from `onClose`), `roomPeers` (pure selection,
  `exclude` support — unit-testable), `broadcast` (copies under read
  lock, sends outside; powpow `sendSafe` skips dead/nil sockets),
  `roomCount`, `rooms`, `memberRooms`.
- `requireWsSession(req, res): HttpCode` — `router.ws` middleware using
  the core session store (`204` valid / `403` otherwise).
- `upgradeWs(req, res, onOpen/onMessage/onClose/onError, protocols,
  maxFrameSize)` — wraps powpow `websocketUpgrade` with the route's
  `powRes`/`powReq`, marks `responseSent` so `supranim.nim`'s WS branch
  returns cleanly. Returns `nil` when the client missed WS headers.

### `src/supranim/support/view.nim` (new)
- `escapeHtml`, `renderTemplate` (`{{key}}` escaped / `{{{key}}}` raw,
  unknown → `""`, unclosed stays literal; `TableRef` + `openArray` overloads),
  `layout` (HTML5 shell, escaped title), `renderPage`, `respondPage`
  dirty template mirroring `json` (incl. `--app:lib` `res[]` branch).
- Full apps keep using Tim via the starter (`tim.nim` layouts/partials);
  this covers core needs (error pages, small HTML) with zero deps.

### Supporting edits
- `network/websocket.nim`: docs point to `support/ws`.
- `network/webserver.nim`: exported `headersFetched`/`headersCache`
  (lets tests/users build fake `Request`s with cookie headers).
- `support/session.nim` + `support/ws.nim`: `{.gcsafe.}` on the four
  lock-guarded global accessors so `gcsafe` route handlers can use
  `withSession`/`defaultHub` (verified via `examples/ws_rooms.nim`).
- `support/ws.nim`, `support/view.nim`: `from std/httpcore import ...`
  (middleware.nim style) instead of redundant full+from imports.
- `examples/ws_rooms.nim` (new): session-cookie index page + `ws`-routed
  rooms chat (`requireWsSession` middleware, `upgradeWs`, broadcast
  minus sender). `clue check` clean.
- `README.md`: WS line → rooms/broadcast/session-aware upgrades;
  templating line → core `support/view` + Tim via starter.

## Tests
- `tests/test_ws.nim` (8 tests): join idempotent/count, nil-safe,
  leave drops rooms, leaveAll/memberRooms, peers exclude, broadcast
  no-op on missing/nil-transport rooms, singleton, `requireWsSession`
  allow/reject/expired via fake-cookie `Request`s.
- `tests/test_view.nim` (9 tests): escaping, escaped/raw/unknown/unclosed
  interpolation, seq + TableRef overloads, layout shell, `respondPage`
  code/headers/body (mirrors `test_response` `gRes` pattern).
- Full suite: 28/28 pass via `clue test`.
