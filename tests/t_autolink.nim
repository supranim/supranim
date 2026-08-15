#
# Unit tests for supranim/core/autolink
#
import std/unittest
import std/[httpcore, options, strutils]

import supranim/core/autolink

suite "autolinkController":
  test "static route maps to a controller handle":
    let a = autolinkController("/users", HttpGet)
    check a.handleName == "getUsers"
    check a.path == "/users"
    check a.regexPath == "\\/users$"
    check a.params.isNone

  test "root path maps to the Homepage handle":
    let a = autolinkController("/", HttpGet)
    check a.handleName == "getHomepage"
    check a.regexPath == "\\/$"

  test "multiple path segments produce a camel-cased handle":
    let a = autolinkController("/users/profile/details", HttpGet)
    check a.handleName == "getUsersProfileDetails"

  test "the http method drives the handle prefix":
    check autolinkController("/users", HttpGet).handleName == "getUsers"
    check autolinkController("/users", HttpPost).handleName == "postUsers"
    check autolinkController("/users", HttpDelete).handleName == "deleteUsers"

  test "dynamic route extracts a named param":
    let a = autolinkController("/electronics/{category:id}", HttpGet)
    check a.handleName == "getElectronicsCategory"
    check a.params.isSome
    check a.params.get == @[("category", false)]
    check "category" in a.regexPath

  test "named pattern selects the regex for that type":
    let a = autolinkController("/blog/{slug:slug}", HttpGet)
    check a.handleName == "getBlogSlug"
    check "[0-9A-Za-z-_]+" in a.regexPath

  test "optional param is flagged and wrapped":
    let a = autolinkController("/search/{q:slug?}", HttpGet)
    check a.params.get == @[("q", true)]
    check "([0-9A-Za-z-_]+)?" in a.regexPath

  test "websocket routes use the ws prefix":
    let a = autolinkController("/chat", HttpGet, isWebSocket = true)
    check a.handleName == "wsChat"

  test "unknown pattern raises ValueError":
    expect ValueError:
      discard autolinkController("/a/{b:nope}", HttpGet)

  test "optional pattern missing closing brace raises ValueError":
    expect ValueError:
      discard autolinkController("/a/{b:slug?x}", HttpGet)

  test "pattern missing closing brace currently crashes with IndexDefect":
    # NOTE: `autolinkController` indexes past the end of the path when the
    # closing `}` is missing, raising an IndexDefect instead of a ValueError.
    # This asserts the current (buggy) behaviour so it is visible in tests.
    expect IndexDefect:
      discard autolinkController("/a/{b:id", HttpGet)
