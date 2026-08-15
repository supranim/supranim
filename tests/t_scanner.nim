#
# Unit tests for supranim/support/scanner
#
import std/unittest

import supranim/support/scanner

suite "Scanner":
  test "isEmail":
    check isEmail("user@example.com")
    check not isEmail("not-an-email")
    check not isEmail("user@example")

  test "isUsername":
    check isUsername("jane_doe123")
    check not isUsername("1short")

  test "isSlug":
    check isSlug("my-blog-post")
    check not isSlug("My Blog Post")

  test "isUUID":
    check isUUID("550e8400-e29b-41d4-a716-446655440000")
    check not isUUID("not-a-uuid")

  test "isJWT":
    check isJWT("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.signature")
    check not isJWT("just-a-string")

  test "isSemVer":
    check isSemVer("1.2.3")
    check not isSemVer("v1.2.3")

  test "isHexColor":
    check isHexColor("#ff0000")
    check not isHexColor("red")

  test "isURL":
    check isURL("https://example.com")
    check not isURL("example.com")

  test "isDomain":
    check isDomain("example.com")
    check not isDomain("not a domain")

  test "isE164":
    check isE164("+15551234567")
    check not isE164("1555")

  test "scanFind finds leftmost match":
    let m = scanEmailFind("foo a@b.co bar")
    check m.matched
    check m.capture("foo a@b.co bar") == "a@b.co"

  test "scanAll finds all non-overlapping matches":
    check scanEmailAll("a@b.co and c@d.co").len == 2
    check scanMentionAll("Hey @alice and @bob!").len == 2

  test "reusable scanner":
    var s = newScanner(PatternEmail)
    let r = s.scanFind("contact me at a@b.co")
    check r.matched
    check r.capture("contact me at a@b.co") == "a@b.co"

  test "captures extracts named/capture groups":
    var s = newScanner(PatternMarkdownLink)
    let m = s.scanFind("see [docs](https://example.com) now")
    check m.matched
    check m.capture("see [docs](https://example.com) now") == "[docs](https://example.com)"

