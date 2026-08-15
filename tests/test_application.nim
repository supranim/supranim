#
# Unit tests for supranim/core/application (macro pipeline)
#
import std/unittest
import std/[httpcore, macrocache, tables]

import supranim/application
import supranim/controller
import supranim/core/router
import supranim/core/request
import supranim/core/response
import supranim/support/uuid

newController getHomepage:
  res.setBody("homepage")

newController getUsers:
  res.setBody("users")

newController getUsersIdProfile:
  res.setBody("profile:" & req.params.getOrDefault("id"))

proc get4xx(req: var Request, res: var Response) {.gcsafe.} =
  res.setCode(Http404)
  res.setBody("custom 404")

routes:
  get "/"
  get "/users"
  get "/users/{id:id}/profile"

suite "Application (macro pipeline)":
  test "initApplication returns a singleton instance":
    let app = appInstance()
    check app != nil
    check appInstance() == app
    check AppInstance() == app

  test "application paths are initialized":
    let app = appInstance()
    check app.paths != nil

  test "config reads from the configs table":
    initApplication()
    # the `init` macro normally populates `App.configs`; set it up manually here
    App.configs = newOrderedTable[string, YamlObject]()
    App.configs["server"] = parseYAML("port: 8080")
    check App.config("server.port").getInt == 8080
    # a top-level id that is not present returns nil
    check App.config("missing.key").isNil
    # a nested key that is missing raises KeyError from the YAML getter
    expect KeyError:
      discard App.config("server.unknown")

  test "initHttpRouter registers routes from the routes: macro":
    initApplication()
    initHttpRouter()
    check App.router != nil

    let home = App.router.checkExists("/", HttpGet)
    check home.exists
    check home.route != nil

    let users = App.router.checkExists("/users", HttpGet)
    check users.exists

    let profile = App.router.checkExists("/users/42/profile", HttpGet)
    check profile.exists
    check profile.params["id"] == "42"

    # wrong method / unknown path
    check not App.router.checkExists("/users", HttpPost).exists
    check not App.router.checkExists("/nope", HttpGet).exists

  test "error handler is registered on init":
    initApplication()
    initHttpRouter()
    check App.router.httpErrors.hasKey("4xx")

  test "app key and port accessors":
    initApplication()
    check App.getUuid().bytes.len == 16
    check int(App.getPort()) == 0
    check App.getAddress() == ""
