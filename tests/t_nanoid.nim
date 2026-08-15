#
# Unit tests for supranim/support/nanoid
#
import std/unittest

import supranim/support/nanoid

suite "NanoID":
  test "generate() uses the default alphabet and length":
    let id = generate()
    check id.len == 21
    for c in id:
      check c in defaultAlphabet

  test "generate() produces unique ids":
    check generate() != generate()

  test "custom alphabet and size":
    let id = generate("abc", 8)
    check id.len == 8
    for c in id:
      check c in "abc"

  test "empty alphabet returns an empty string":
    check generate("") == ""

  test "size < 1 returns an empty string":
    check generate(defaultAlphabet, 0) == ""
    check generate(defaultAlphabet, -5) == ""

  test "single character alphabet":
    check generate("a", 5) == "aaaaa"
