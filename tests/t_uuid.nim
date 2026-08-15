#
# Unit tests for supranim/support/uuid (backed by pkg/openparser/uuid)
#
import std/unittest
import std/strutils

import supranim/support/uuid

suite "UUID":
  const KnownUuid = "550e8400-e29b-41d4-a716-446655440000"
  const KnownUuidHex = "550e8400e29b41d4a716446655440000"

  test "newUuidV4() generates an RFC-4122 version 4 UUID":
    let u = newUuidV4()
    check u.variant == variantRFC4122
    check u.version == 4
    check ($u).len == 36
    check ($u).count('-') == 4

  test "newUuidV4() generates unique values":
    check newUuidV4() != newUuidV4()

  test "v4() is an alias of newUuidV4()":
    let u = v4()
    check u.version == 4
    check u.variant == variantRFC4122

  test "parseUuid parses a canonical 8-4-4-4-12 UUID string":
    let u = parseUuid(KnownUuid)
    check $u == KnownUuid

  test "parseUuid accepts a 32-char hex string (no hyphens)":
    check $parseUuid(KnownUuidHex) == KnownUuid

  test "parseUuid is case-insensitive":
    check $parseUuid("550E8400-E29B-41D4-A716-446655440000") == KnownUuid

  test "parseUuid rejects invalid length":
    expect UuidError:
      discard parseUuid("too-short")

  test "parseUuid rejects invalid hex characters":
    # `parseHexInt` raises a plain ValueError for non-hex input
    expect ValueError:
      discard parseUuid("550e8400-e29b-41d4-a716-44665544000g")

  test "isValidUuid":
    check isValidUuid(KnownUuid)
    check isValidUuid(KnownUuidHex)
    check not isValidUuid("not-a-uuid")

  test "uuid bytes are accessible":
    let u = parseUuid(KnownUuid)
    check u.bytes.len == 16

  test "nilUuid and isNil":
    check nilUuid().isNil
    check not parseUuid(KnownUuid).isNil

  test "equality is byte-based":
    check parseUuid(KnownUuid) == parseUuid(KnownUuid)
    check parseUuid(KnownUuid) != newUuidV4()
