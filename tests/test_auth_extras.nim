#
# Unit tests for supranim/support/auth additions
# (password hashing via nimcypher re-export + session helpers)
#
import std/unittest
import std/strutils

import supranim/support/auth

suite "support/auth extras":
  test "hashPassword / verifyPassword round-trip (Argon2id)":
    let stored = hashPassword("Secret123!")
    check stored.contains(":")
    check verifyPassword("Secret123!", stored)
    check not verifyPassword("wrong", stored)
    check not verifyPassword("Secret123!", "bogus")
    check not verifyPassword("Secret123!", "a:b")

  test "generateSessionId length and uniqueness":
    check generateSessionId().len == 32
    check generateSessionId(42).len == 42
    check generateSessionId() != generateSessionId()

  test "isStrongPassword":
    check isStrongPassword("Secret123")
    check not isStrongPassword("weak")
    check not isStrongPassword("alllowercase1")
    check not isStrongPassword("NODIGITSHERE")
