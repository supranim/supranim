#
# Unit tests for supranim/support/http
#
import std/unittest

import supranim/support/http

suite "support/http":
  test "normalizePath collapses repeated slashes":
    check normalizePath("//foo//bar") == "/foo/bar"
    check normalizePath("///") == "/"
    check normalizePath("a//b///c") == "a/b/c"

  test "normalizePath leaves well-formed paths unchanged":
    check normalizePath("/") == "/"
    check normalizePath("") == ""
    check normalizePath("a/b/c") == "a/b/c"
    check normalizePath("/users/42") == "/users/42"
