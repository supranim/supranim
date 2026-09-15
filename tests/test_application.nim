#
# Unit tests for supranim/core/application (macro pipeline)
#
import std/unittest
import std/[httpcore, macrocache, tables, os]

import supranim/application
import supranim/controller
import supranim/core/config
import supranim/core/router
import supranim/core/request
import supranim/core/response
import supranim/support/uuid

const fixtureDir = currentSourcePath().parentDir / "fixtures" / "staticconf"
const dupDir = currentSourcePath().parentDir / "fixtures" / "staticdup"

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
    App.configs = newOrderedTable[string, Configuration]()
    App.configs["server"] = parseConfiguration(".yml", "port: 8080")
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

suite "Application configuration formats":
  test "each format parses natively into the Configuration variant":
    let yml = parseConfiguration(".yml", "port: 8080")
    check yml.format == cfgYaml
    check yml.get("port").getInt == 8080

    let yamlExt = parseConfiguration(".yaml", "port: 8081")
    check yamlExt.format == cfgYaml

    let toml = parseConfiguration(".toml", "port = 7070")
    check toml.format == cfgToml
    check toml.get("port").getInt == 7070

    let json = parseConfiguration(".json", """{"port": 9090}""")
    check json.format == cfgJson
    check json.get("port").getInt == 9090

  test "unknown extensions raise ConfigError":
    expect ConfigError:
      discard parseConfiguration(".ini", "port = 1")

  test "broken documents raise ConfigError":
    expect ConfigError:
      discard parseConfiguration(".yml", "port: [unclosed")
    expect ConfigError:
      discard parseConfiguration(".toml", "port = = broken")
    expect ConfigError:
      discard parseConfiguration(".json", "{broken")

  test "loadConfigurations strips static blocks at load time":
    let docs = loadConfigurations(fixtureDir)
    check docs.hasKey("app")
    check docs.hasKey("db")
    check docs.hasKey("extra")
    # `static` is gone from the runtime store in every format
    check not docs["app"].yamlDoc.hasKey("static")
    check not docs["db"].tomlDoc.tableVal.hasKey("static")
    check not docs["extra"].jsonDoc.hasKey("static")
    # runtime keys survive in every format
    check docs["app"].get("url").getStr == "https://example.com"
    check docs["app"].get("ssl").getBool == true
    check docs["db"].get("server.port").getInt == 7071
    check docs["extra"].get("endpoint").getStr == "https://api.example.com"

  test "same base name in two formats raises ConfigError":
    expect ConfigError:
      discard loadConfigurations(dupDir)

  test "runtime config() serves all formats through ConfigValue":
    initApplication()
    App.configs = loadConfigurations(fixtureDir)
    check App.config("app.url").getStr == "https://example.com"
    check App.config("db.server.port").getInt == 7071
    check App.config("extra.endpoint").getStr == "https://api.example.com"
    check App.config("missing.key").isNil
    # missing nested keys surface a nil node (no raise) in every format
    check App.config("app.db.missing").isNil
    check App.config("db.missing").isNil
    check App.config("extra.missing").isNil
    # files without a `static` block load normally
    check App.config("nostatic.url").getStr == "https://nostatic.example.com"
    check App.config("nostatic.port").getInt == 1234

  test "putters round-trip natively per format":
    var y = parseConfiguration(".yml", "a: 1")
    y.putStr("s", "hi")
    y.putInt("n", 42)
    y.putFloat("f", 1.5)
    y.putBool("b", true)
    check y.get("s").getStr == "hi"
    check y.get("n").getInt == 42
    check y.get("f").getFloat == 1.5
    check y.get("b").getBool == true
    check y.get("a").getInt == 1

    var t = parseConfiguration(".toml", "a = 1")
    t.putStr("s", "hi")
    t.putInt("n", 42)
    t.putFloat("f", 2.5)
    t.putBool("b", false)
    check t.get("s").getStr == "hi"
    check t.get("n").getInt == 42
    check t.get("f").getFloat == 2.5
    check t.get("b").getBool == false

    var j = parseConfiguration(".json", """{"a": 1}""")
    j.putStr("s", "hi")
    j.putInt("n", 42)
    j.putFloat("f", 0.5)
    j.putBool("b", true)
    check j.get("s").getStr == "hi"
    check j.get("n").getInt == 42
    check j.get("f").getFloat == 0.5
    check j.get("b").getBool == true
    # ints coerce to float on read
    check j.get("a").getFloat == 1.0

suite "Compile-time staticConfig":
  type DbConf = object
    host: string
    pools: int

  test "scalars from yaml, toml and json static blocks":
    check staticConfigFromDir[bool](fixtureDir, "app.enable_feature") == true
    check staticConfigFromDir[bool](fixtureDir, "app.debug") == false
    check staticConfigFromDir[int](fixtureDir, "app.port") == 8080
    check staticConfigFromDir[float](fixtureDir, "app.ratio") == 1.5
    check staticConfigFromDir[string](fixtureDir, "app.name") == "supranim"
    check staticConfigFromDir[bool](fixtureDir, "db.enable_feature") == false
    check staticConfigFromDir[int](fixtureDir, "db.port") == 7070
    check staticConfigFromDir[string](fixtureDir, "db.name") == "supra-toml"
    check staticConfigFromDir[int](fixtureDir, "extra.retries") == 3
    check staticConfigFromDir[string](fixtureDir, "extra.prefix") == "extra"

  test "collections and objects from static blocks":
    check staticConfigFromDir[seq[string]](fixtureDir, "app.tags") == @["web", "api"]
    check staticConfigFromDir[seq[string]](fixtureDir, "db.tags") == @["queue", "worker"]
    let db = staticConfigFromDir[DbConf](fixtureDir, "app.db")
    check db.host == "localhost"
    check db.pools == 4
    let tomlDb = staticConfigFromDir[DbConf](fixtureDir, "db.db")
    check tomlDb.host == "tomlhost"
    check tomlDb.pools == 2
    # nested scalars at depth
    check staticConfigFromDir[string](fixtureDir, "app.db.host") == "localhost"
    check staticConfigFromDir[int](fixtureDir, "app.db.pools") == 4
    check staticConfigFromDir[seq[string]](fixtureDir, "extra.tags") == @["json"]
    # named tuples map from objects too
    let dbTuple = staticConfigFromDir[tuple[host: string, pools: int]](fixtureDir, "app.db")
    check dbTuple.host == "localhost"
    check dbTuple.pools == 4

  test "staticConfig works in static and when contexts":
    static:
      doAssert staticConfigFromDir[bool](fixtureDir, "app.enable_feature")
    when staticConfigFromDir[bool](fixtureDir, "extra.enable_feature"):
      check true
    else:
      check false
    when staticConfigFromDir[bool](fixtureDir, "db.enable_feature"):
      check false
    else:
      check true

  test "unknown files, keys and type mismatches fail to compile":
    check not compiles(staticConfigFromDir[bool](fixtureDir, "nope.flag"))
    check not compiles(staticConfigFromDir[bool](fixtureDir, "app.missing"))
    check not compiles(staticConfigFromDir[bool](fixtureDir, "app.db.missing"))
    check not compiles(staticConfigFromDir[bool](fixtureDir, "app.name"))
    check not compiles(staticConfigFromDir[bool](fixtureDir, "app"))
    # files without a `static` block cannot serve static keys
    check not compiles(staticConfigFromDir[string](fixtureDir, "nostatic.url"))
    # base-name collisions across formats fail at compile time too
    check not compiles(staticConfigFromDir[int](dupDir, "dup.port"))
