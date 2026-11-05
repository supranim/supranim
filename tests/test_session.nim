#
# Unit tests for supranim/support/session (core in-memory store)
#
import std/unittest
import std/[options, tables, times]

import supranim/support/session

suite "support/session":
  test "createSession returns unique ids":
    let store = newSessionStore()
    let a = store.createSession()
    let b = store.createSession()
    check a.id.len == 42
    check b.id.len == 42
    check a.id != b.id
    check store.sessionCount() == 2

  test "getSession / hasSession / destroySession":
    let store = newSessionStore()
    let s = store.createSession(some("user-1"))
    check store.hasSession(s.id)
    check store.getSession(s.id) == s
    check store.getSession(s.id).getUserId() == some("user-1")
    check store.getSession("missing").isNil
    store.destroySession(s.id)
    check not store.hasSession(s.id)
    check store.getSession(s.id).isNil

  test "renewSessionId changes id and preserves object":
    let store = newSessionStore()
    let s = store.createSession()
    let oldId = s.id
    let newId = store.renewSessionId(s)
    check newId != oldId
    check s.id == newId
    check not store.hasSession(oldId)
    check store.hasSession(newId)

  test "expired sessions are purged on access and via cleanupExpired":
    var cfg = defaultSessionConfig()
    cfg.expiration = initDuration(milliseconds = 1)
    let store = newSessionStore(cfg)
    let s = store.createSession()
    # force expiry by backdating
    s.created = now() - initDuration(hours = 1)
    check store.getSession(s.id).isNil
    check not store.hasSession(s.id)
    let s2 = store.createSession()
    s2.created = now() - initDuration(hours = 1)
    check store.cleanupExpired() == 1
    check store.sessionCount() == 0

  test "CSRF tokens are stable then single-use":
    let store = newSessionStore()
    let s = store.createSession()
    let t1 = s.genCSRF("/auth/login")
    let t2 = s.genCSRF("/auth/login")
    check t1.len > 0
    check t1 == t2
    check s.validateCSRF("/auth/login", t1)
    # consumed
    check not s.validateCSRF("/auth/login", t1)
    check not s.validateCSRF("/auth/login", "bogus")

  test "flash notifications round-trip then clear":
    let store = newSessionStore()
    let s = store.createSession()
    s.notify("welcome", "/")
    s.notify("second", "/")
    check s.getNotifications("/") == @["welcome", "second"]
    check s.getNotifications("/").len == 0

  test "payload helpers":
    let store = newSessionStore()
    let s = store.createSession()
    s.setPayloadValue("role", "admin")
    check s.getPayloadValue("role") == some("admin")
    check s.getPayloadValue("missing").isNone
    s.setUserId("u-42")
    check s.getUserId() == some("u-42")

  test "default store singleton is stable":
    let a = defaultStoreInit()
    let b = defaultStoreInit()
    check a == b
    # isolate other tests
    setDefaultSessionStore(newSessionStore())
