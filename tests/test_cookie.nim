#
# Unit tests for supranim/support/cookie
#
import std/unittest
import std/[times, options, tables, strutils]
from std/cookies import SameSite

import supranim/support/cookie

suite "Cookie":
  test "default cookie serializes with all default attributes":
    let c = newCookie("user", "john", secure = true, httpOnly = true)
    check $c == "user=john;HttpOnly;Path=/;Secure;SameSite=Strict;"

  test "full cookie serializes all attributes in order":
    let c = newCookie(
      "sid", "abc",
      expirationDate = some(now() + 1.days),
      maxAge = some(3600),
      domain = "example.com",
      path = "/",
      secure = true,
      httpOnly = false,
      sameSite = SameSite.Lax
    )
    let s = $c
    check s.startsWith("sid=abc;Expires=")
    check "Max-Age=3600;" in s
    check "Domain=example.com;" in s
    check "Path=/;" in s
    check "Secure;" in s
    check "SameSite=Lax;" in s
    # no HttpOnly for this cookie
    check "HttpOnly" notin s

  test "accessors":
    let c = newCookie("sid", "abc", domain = "example.com", secure = true)
    check c.getName == "sid"
    check c.getValue == "abc"
    check c.getDomain == "example.com"

  test "parseCookies parses a cookie header":
    let parsed = parseCookies("a=1; b=2")
    check not parsed.isNil
    check parsed["a"].getValue == "1"
    check parsed["b"].getValue == "2"
    # parsed cookies are given a short-lived expiry
    check parsed["a"].isExpired == false

  test "parseCookies of an empty string returns nil":
    check parseCookies("").isNil

  test "isExpired for session/persistent cookies":
    let session = newCookie("x", "y", secure = true)
    check session.isExpired == false
    let persistent = newCookie("x", "y", expirationDate = some(now() - 1.hours), secure = true)
    check persistent.isExpired == true

  test "expires() pushes the cookie into the past":
    var c = newCookie("s", "v", secure = true)
    check c.isExpired == false
    c.expires()
    check c.isExpired == true
