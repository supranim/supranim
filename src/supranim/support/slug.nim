#
# Supranim is a full-featured web framework for building
# web apps & microservices in Nim.
# 
#   (c) 2026 LGPL-v3-or-later License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#
import std/[unidecode, strutils]

## This module implements a simple slug generator that converts a string to a URL-friendly format.
## The `slugify` procedure takes an input string and converts it to a slug by:
## - Removing leading and trailing whitespace
## - Replacing sequences of whitespace and punctuation with a specified separator (default is '-')
## - Converting all characters to lowercase
## - Optionally allowing slashes if `allowSlash` is set to true
## 
## It uses the `unidecode` library to convert non-ASCII characters to their closest ASCII equivalents,
## ensuring that the resulting slug is URL-friendly and readable

proc slugify*(str: string, sep: static char = '-', allowSlash: bool = false): string =
  ## Convert `input` string to a ascii slug
  var x = unidecode(str.strip())
  result = newStringOfCap(x.len)
  var i = 0
  while i < x.len:
    case x[i]
    of Whitespace:
      inc i
      try:
        while x[i] notin IdentChars:
          inc i
        add result, sep
      except IndexDefect: discard
    of PunctuationChars:
      inc i
      if result.len == 0: continue
      if allowSlash and x[i - 1] == '/':
        add result, '/'
        continue
      try:
        while x[i] notin IdentChars:
          inc i
        add result, sep
      except IndexDefect:
        discard
    else:
      add result, x[i].toLowerAscii
      inc i

proc generate*(str: string, sep: static char = '-'): string {.inline.} =
  ## An alias of `slugify`
  slugify(str, sep)