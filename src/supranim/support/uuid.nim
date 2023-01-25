# Supranim is a simple MVC-style web framework for building
# fast web applications, REST API microservices and other cool things.
# 
# This is a pure UUIDv4 implementation originally written by Matt Cooper
# https://github.com/vtbassmatt
#
# (c) 2021 Supranim is released under MIT License
#          Made by Humans from OpenPeep
#          https://supranim.com | https://github.com/supranim

import std/[sysrand, strformat, hashes]

from std/strutils import toHex, replace, split, join
from std/parseutils import parseHex

type
  UuidVariant* {.pure.} = enum
    ApolloNcs, RFC4122, ReservedFuture, ReservedMicrosoft

  Uuid* = object
    bytes: array[16, uint8]
    strv: string

  UUIDError* = object of CatchableError

proc hexify(bytes: openArray[uint8]): string =
  for byte in bytes:
    result = result & fmt"{byte:02x}"

proc toStr(uuid: Uuid): string =
  result = hexify(uuid.bytes[0..3]) & "-" &
       hexify(uuid.bytes[4..5]) & "-" &
       hexify(uuid.bytes[6..7]) & "-" &
       hexify(uuid.bytes[8..9]) & "-" &
       hexify(uuid.bytes[10..15])

proc uuid4*(): Uuid =
  let success = result.bytes.urandom()
  if success:
    result.bytes[6] = (result.bytes[6] and 0x0F) or 0x40
    result.bytes[8] = (result.bytes[8] and 0x3F) or 0x80
    result.strv = result.toStr()

proc normalizeUuidStr(candidateStr: string): string =
  let uuidStr = candidateStr.split('-').join()
  if len(uuidStr) != 32:
    raise newException(UUIDError,
      "expected 8-4-4-4-12 or 32 characters format")
  result = uuidStr

proc variant*(self: Uuid): UuidVariant =
  ## Determine the variant of the UUID.
  ## Most in the wild are RFC-4122.
  # borrowed tricks from CPython's uuid library
  let invByte = not self.bytes[8]
  if (invByte and 0x80) == 0x80:
    return UuidVariant.ApolloNcs
  elif (invByte and 0x40) == 0x40:
    return UuidVariant.Rfc4122
  elif (invByte and 0x20) == 0x20:
    return UuidVariant.ReservedMicrosoft
  return UuidVariant.ReservedFuture

proc version*(self: Uuid): int =
  ## Determine the version of an RFC-4122 UUID.
  if self.variant == UuidVariant.Rfc4122:
    result = int((self.bytes[6] and 0xF0) shr 4)

proc uuid4*(uuidStr: string): Uuid =
  ## Parse a UUID from a string (with or without hyphens, any casing).
  let uuidStrClean = normalizeUuidStr(uuidStr)
  # idx is the index into the result's bytes array; it must be doubled
  # to index into the string. We know that the string is 32 characters
  # because we normalized it above.
  # assert uuidStrClean.len == 32
  for idx in 0 .. 15:
    let byteStr = uuidStrClean[2*idx .. 2*idx+1]
    if parseHex(byteStr, result.bytes[idx]) != 2:
      raise newException(UUIDError,
        "Could not parse a hex character from " & fmt"'{byteStr}' at index {2*idx}")
  result.strv = result.toStr()

proc uuid4*(uuidBytes: array[16, uint8]): Uuid =
  ## Create a UUID directly from 16 bytes.
  result.bytes = uuidBytes

proc `$`*(uuid: Uuid): string =
  ## Return the string version of `UUID`
  result = uuid.strv

proc `$$`*(uuid: Uuid): string =
  ## Return the string version of `UUID` without hyphens
  result = replace(uuid.strv, "-", toHex("-"))
