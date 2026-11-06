#
# Supranim is a high-performance web framework for building
# web applications and microservices in Nim
#
#   (c) 2026 LGPL-v3-or-later License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#

## Lightweight in-memory session manager for Supranim core.
##
## This module provides the minimal building blocks that were missing
## from core: session creation, lookup, renewal, expiry, CSRF tokens
## and flash notifications — without requiring a database or the
## out-of-tree `supranim-session` provider.
##
## For persistent, multi-process or DB-backed sessions (users table,
## remember-me, 2FA, email confirmation) use `supranim-session`.
## This core store is process-local and suitable for single-instance
## apps, tests and as a foundation for custom providers.
##
## Thread safety: all `SessionStore` mutations are guarded by
## `pkg/threading/rwlock`. Read paths use `readWith`, writes use
## `writeWith`, matching the convention in `supranim-session`.

import std/[options, tables, times, strutils, json, locks]
from std/cookies import SameSite

import pkg/threading/rwlock
import pkg/nimcypher

import ./cookie
import ./nanoid

from ../core/request import Request, hasCookies, getCookies,
  getClientData, getUriPath, newCookieForRequest
from ../core/response import Response, addHeader

export cookie

type
  SessionConfig* = object
    ## Code-first configuration. No config file required.
    cookieName*: string
    expiration*: Duration
    cookieDomain*: string
    cookiePath*: string
    httpOnly*: bool
    sameSite*: SameSite
    secure*: CookieSecureMode
    trustProxy*: bool

  Session* = ref object
    ## A single user session.
    id*: string
    userId*: Option[string]
    payload*: tables.Table[string, string]
    created*: DateTime
    lastAccess*: DateTime
    csrfSecret*: string
    csrfTokens*: Table[string, string]
    flash*: Table[string, seq[string]]

  SessionStore* = ref object
    ## Process-local session container.
    config*: SessionConfig
    sessions*: Table[string, Session]
    lock: RwLock

proc defaultSessionConfig*(): SessionConfig =
  ## Sensible defaults: `ssid` cookie, 720h expiry,
  ## Safari-safe `secureAuto`, host-only domain.
  SessionConfig(
    cookieName: "ssid",
    expiration: initDuration(hours = 720),
    cookieDomain: "",
    cookiePath: "/",
    httpOnly: true,
    sameSite: Strict,
    secure: secureAuto,
    trustProxy: false
  )

proc newSessionStore*(config = defaultSessionConfig()): SessionStore =
  ## Creates an empty `SessionStore` with the given config.
  SessionStore(
    config: config,
    sessions: initTable[string, Session](),
    lock: createRwLock()
  )

var defaultStore {.global.}: SessionStore
var defaultStoreLock {.global.}: Lock
initLock(defaultStoreLock)

proc defaultStoreInit*(): SessionStore {.gcsafe.} =
  ## Returns the process-global default store, creating it on first use.
  ## Lock-guarded; the `gcsafe` blocks assert manual safety for the
  ## shared global (same pattern as `supranim-session`'s singleton).
  {.gcsafe.}:
    withLock(defaultStoreLock):
      if defaultStore.isNil:
        defaultStore = newSessionStore()
      result = defaultStore

proc setDefaultSessionStore*(store: SessionStore) {.gcsafe.} =
  ## Replaces the process-global default store (useful in tests).
  {.gcsafe.}:
    withLock(defaultStoreLock):
      defaultStore = store

proc sessionCookieName*(store: SessionStore): string =
  ## Resolves the cookie name, falling back to `ssid`.
  if store.config.cookieName.len > 0: store.config.cookieName
  else: "ssid"

proc isExpired*(s: Session, store: SessionStore): bool =
  ## True when `now - created` exceeds the configured expiration.
  now() - s.created > store.config.expiration

proc createSession*(store: SessionStore,
    userId = none(string)): Session =
  ## Creates, registers and returns a new session with a unique id.
  ## Retries on NanoID collision.
  result = Session(
    userId: userId,
    payload: initTable[string, string](),
    created: now(),
    csrfSecret: nanoid.generate(size = 32),
    csrfTokens: initTable[string, string](),
    flash: initTable[string, seq[string]]()
  )
  result.lastAccess = result.created
  writeWith(store.lock):
    while true:
      let id = nanoid.generate(size = 42)
      if not store.sessions.hasKey(id):
        result.id = id
        store.sessions[id] = result
        break

proc getSession*(store: SessionStore, id: string): Session =
  ## Returns the session by id, or `nil` when missing or expired.
  ## Expired sessions are removed lazily on access.
  var expired = false
  readWith(store.lock):
    if store.sessions.hasKey(id):
      result = store.sessions[id]
      if now() - result.created > store.config.expiration:
        expired = true
        result = nil
  if expired:
    writeWith(store.lock):
      store.sessions.del(id)

proc hasSession*(store: SessionStore, id: string): bool =
  ## True when a non-expired session exists for `id`.
  not store.getSession(id).isNil

proc destroySession*(store: SessionStore, id: string) =
  ## Deletes a session by id. No-op when missing.
  writeWith(store.lock):
    store.sessions.del(id)

proc destroySession*(store: SessionStore, s: Session) =
  ## Deletes a session object.
  if not s.isNil:
    store.destroySession(s.id)

proc touchSession*(store: SessionStore, s: Session) =
  ## Refreshes `lastAccess` without changing the id.
  writeWith(store.lock):
    if store.sessions.hasKey(s.id):
      s.lastAccess = now()

proc renewSessionId*(store: SessionStore, s: Session): string =
  ## Regenerates the session id (call after login to prevent fixation).
  ## Returns the new id.
  writeWith(store.lock):
    let oldId = s.id
    while true:
      let newId = nanoid.generate(size = 42)
      if not store.sessions.hasKey(newId):
        s.id = newId
        store.sessions.del(oldId)
        store.sessions[newId] = s
        break
  result = s.id

proc cleanupExpired*(store: SessionStore): int =
  ## Removes all expired sessions. Returns the number removed.
  ## Call periodically (timer, background thread, or per-request sampling).
  var expired: seq[string]
  readWith(store.lock):
    for id, s in store.sessions:
      if now() - s.created > store.config.expiration:
        expired.add(id)
  if expired.len > 0:
    writeWith(store.lock):
      for id in expired:
        if store.sessions.hasKey(id):
          let s = store.sessions[id]
          if now() - s.created > store.config.expiration:
            store.sessions.del(id)
  result = expired.len

proc sessionCount*(store: SessionStore): int =
  ## Number of sessions currently held (including expired not yet GC'd).
  readWith(store.lock):
    result = store.sessions.len

# Payload helpers

proc setUserId*(s: Session, userId: string) =
  ## Associates a user id with the session (call after verifying credentials).
  s.userId = some(userId)

proc getUserId*(s: Session): Option[string] =
  ## Returns the associated user id, if any.
  s.userId

proc setPayloadValue*(s: Session, key, value: string) =
  ## Stores an arbitrary string value in the session payload.
  s.payload[key] = value

proc getPayloadValue*(s: Session, key: string): Option[string] =
  ## Returns a payload value, if present.
  if s.payload.hasKey(key):
    return some(s.payload[key])

# CSRF helpers (HMAC-SHA512 of random bytes under per-session secret)

proc genCSRF*(s: Session, formId: string): string =
  ## Returns a stable CSRF token for `formId`, generating it on first use.
  if s.csrfTokens.hasKey(formId):
    return s.csrfTokens[formId]
  result = toLowerAscii(sha512HmacHex(s.csrfSecret, nanoid.generate(size = 8)))
  s.csrfTokens[formId] = result

proc validateCSRF*(s: Session, formId, clientToken: string): bool =
  ## Validates then consumes a CSRF token (single-use).
  if s.csrfTokens.hasKey(formId) and s.csrfTokens[formId] == clientToken:
    s.csrfTokens.del(formId)
    return true
  false

# Flash notifications

proc notify*(s: Session, msg: string, path = "/") =
  ## Queues a flash message for `path` (shown after redirect).
  if not s.flash.hasKey(path):
    s.flash[path] = @[]
  s.flash[path].add(msg)

proc getNotifications*(s: Session, path: string): seq[string] =
  ## Returns and clears flash messages for `path`.
  if s.flash.hasKey(path):
    result = s.flash[path]
    s.flash.del(path)

# Request / Response integration

proc getSessionIdFromRequest*(req: var Request,
    store: SessionStore): Option[string] =
  ## Reads the session id from the request cookie.
  if req.hasCookies:
    let cookiesOpt = req.getCookies()
    if cookiesOpt.isSome:
      let jar = parseCookies(cookiesOpt.get())
      if not jar.isNil:
        let n = store.sessionCookieName()
        if jar.hasKey(n):
          return some(jar[n].getValue())

proc getSessionIdFromRequest*(req: var Request): Option[string] =
  ## Overload using the process-global default store's cookie name.
  getSessionIdFromRequest(req, defaultStoreInit())

proc buildSessionCookie*(req: var Request, id: string,
    store: SessionStore): Cookie =
  ## Builds a session cookie honoring the store config and the
  ## request's effective scheme (Safari-safe `Secure` handling).
  let c = store.config
  req.newCookieForRequest(store.sessionCookieName(), id,
    mode = c.secure, trustProxy = c.trustProxy,
    domain = c.cookieDomain, path = c.cookiePath,
    httpOnly = c.httpOnly, sameSite = c.sameSite)

proc getSessionFromRequest*(req: var Request,
    store: SessionStore): Session =
  ## Returns the current session, or `nil` when absent/invalid.
  let ssid = req.getSessionIdFromRequest(store)
  if ssid.isSome:
    result = store.getSession(ssid.get())

proc getSessionFromRequest*(req: var Request): Session =
  ## Overload using the default store.
  getSessionFromRequest(req, defaultStoreInit())

proc initSessionWithHeaders*(req: var Request, res: var Response,
    store: SessionStore): Session =
  ## Creates a session and emits a `set-cookie` header.
  ## Clears any stale cookie first so the browser drops it.
  let stale = req.getSessionIdFromRequest(store)
  if stale.isSome:
    var clearCookie = req.buildSessionCookie("", store)
    clearCookie.expires()
    res.addHeader("set-cookie", $clearCookie)
  result = store.createSession()
  # Bind minimal client fingerprint for later hijack detection.
  try:
    let data = req.getClientData()
    if data.hasKey("ip"): result.payload["ip"] = data["ip"].getStr("")
    if data.hasKey("agent"): result.payload["agent"] = data["agent"].getStr("")
  except CatchableError:
    discard
  let cookie = req.buildSessionCookie(result.id, store)
  res.addHeader("set-cookie", $cookie)

proc initSessionWithHeaders*(req: var Request,
    res: var Response): Session =
  ## Overload using the default store.
  initSessionWithHeaders(req, res, defaultStoreInit())

proc destroySessionWithHeaders*(req: var Request, res: var Response,
    store: SessionStore, s: Session) =
  ## Destroys the session and emits an expired cookie so the
  ## browser drops it.
  if s.isNil: return
  var cookie = req.buildSessionCookie(s.id, store)
  cookie.expires()
  res.addHeader("set-cookie", $cookie)
  store.destroySession(s)

proc renewSessionWithHeaders*(req: var Request, res: var Response,
    store: SessionStore, s: Session) =
  ## Renews the session id and emits the replacement cookie.
  discard store.renewSessionId(s)
  let cookie = req.buildSessionCookie(s.id, store)
  res.addHeader("set-cookie", $cookie)

template withSession*(store: SessionStore, body: untyped) {.dirty.} =
  ## Ensures a `userSession: Session` is in scope.
  ## Creates one (with `set-cookie`) when the request has none.
  ## Requires `req: var Request` and `res: var Response` in scope.
  block:
    var userSession {.inject.}: Session = req.getSessionFromRequest(store)
    if userSession.isNil:
      userSession = req.initSessionWithHeaders(res, store)
    else:
      store.touchSession(userSession)
    body

template withSession*(body: untyped) {.dirty.} =
  ## Overload using the default store.
  block:
    let defaultSessionStore {.inject.} = defaultStoreInit()
    withSession(defaultSessionStore, body)
