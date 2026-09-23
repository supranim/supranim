#
# Supranim is a high-performance web framework for building
# web applications and microservices in Nim
# 
#   (c) 2026 LGPL-v3-or-later License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#

## Environment loader for `.env.yml`.
## Reads `rootPath/.env.yml`, parses database credentials, and sets
## `database.*` env vars for the current process.
##
## This module also owns multi-format application configuration:
## `.yml`/`.yaml`, `.toml` and `.json` files are parsed natively into a
## `Configuration` variant (no cross-format conversion), served at runtime
## via `config()` and at compile time via `staticConfig[T]()`.

import std/[macros, os, tables, strutils, algorithm]
import pkg/openparser/[json, yaml, toml]

import ./paths

type
  SupranimEnvLoader* = object of CatchableError
    ## Error raised when the environment file cannot be loaded.

  ConfigError* = object of CatchableError
    ## Error raised when a configuration file cannot be found,
    ## parsed, or resolved (including `static` lookups).

  ConfigurationFormat* = enum
    ## Native format of a configuration document.
    cfgYaml
    cfgToml
    cfgJson

  Configuration* = object
    ## A single parsed configuration file, stored natively.
    ## No conversion between formats ever happens.
    case format*: ConfigurationFormat
    of cfgYaml:
      yamlDoc*: YAMLObject
    of cfgToml:
      tomlDoc*: TomlDocument
    of cfgJson:
      jsonDoc*: JsonNode

  ConfigValue* = object
    ## The result of a dotted-path lookup inside a `Configuration`.
    ## Wraps the native node; use `getStr`/`getInt`/`getFloat`/`getBool`.
    case format*: ConfigurationFormat
    of cfgYaml:
      yamlNode*: YamlNode
    of cfgToml:
      tomlNode*: TomlNode
    of cfgJson:
      jsonNode*: JsonNode

const
  configFileExtensions* = [".yml", ".yaml", ".toml", ".json"]
    ## File extensions recognized as configuration files.

proc loadEnv* =
  ## Loads environment variables from the `.env.yml` file in the project root directory.
  ## 
  if not fileExists(rootPath / ".env.yml"):
    raise newException(SupranimEnvLoader,
        "Configuration file '.env.yml' not found in project root directory.")
  let
    envContents = readFile(rootPath / ".env.yml")
    ymlEnv = parseYAML(envContents)
  when not defined release:
    let
      dbUser = ymlEnv.get("database.local.user").getStr
      dbName = ymlEnv.get("database.local.name").getStr
      dbPassword = ymlEnv.get("database.local.password").getStr
      dbPort = ymlEnv.get("database.local.port").getStr
  else:
    let
      dbUser = ymlEnv.get("database.prod.user").getStr
      dbName = ymlEnv.get("database.prod.name").getStr
      dbPassword = ymlEnv.get("database.prod.password").getStr
      dbPort = ymlEnv.get("database.prod.port").getStr
  
  putEnv("database.user", dbUser)
  putEnv("database.name", dbName)
  putEnv("database.password", dbPassword)
  putEnv("database.port", dbPort)

#
# Multi-format configuration loading
#
proc formatForExt*(ext: string): ConfigurationFormat =
  ## Maps a file extension to its `ConfigurationFormat`.
  ## Raises `ConfigError` for unknown extensions.
  case ext.toLowerAscii
  of ".yml", ".yaml": cfgYaml
  of ".toml": cfgToml
  of ".json": cfgJson
  else:
    raise newException(ConfigError,
      "Unsupported configuration format `" & ext & "`. " &
      "Use one of: .yml, .yaml, .toml, .json")

proc parseConfiguration*(ext, content: string): Configuration =
  ## Parses `content` natively according to `ext`.
  ## Raises `ConfigError` (wrapping the native parser error) on failure.
  let format = formatForExt(ext)
  try:
    case format
    of cfgYaml:
      result = Configuration(format: cfgYaml, yamlDoc: parseYAML(content))
    of cfgToml:
      result = Configuration(format: cfgToml, tomlDoc: parseTOML(content))
    of cfgJson:
      result = Configuration(format: cfgJson, jsonDoc: fromJson(content))
  except ConfigError:
    raise
  except CatchableError as e:
    raise newException(ConfigError, e.msg)

proc stripStatic*(conf: var Configuration) =
  ## Removes the top-level `static` block from `conf`, so compile-time
  ## settings are never visible at runtime.
  case conf.format
  of cfgYaml:
    if conf.yamlDoc.hasKey("static"):
      conf.yamlDoc.del("static")
  of cfgToml:
    if conf.tomlDoc.tableVal.hasKey("static"):
      conf.tomlDoc.tableVal.del("static")
  of cfgJson:
    if conf.jsonDoc.kind == JObject and conf.jsonDoc.hasKey("static"):
      conf.jsonDoc.delete("static")

type
  ConfigEntry* = tuple
    ## A discovered configuration file: base `name` (no extension),
    ## absolute `path`, and file `ext`.
    name, path, ext: string

proc scanConfigDir*(dir: string): seq[ConfigEntry] =
  ## Discovers configuration files in `dir`. The same base name in two
  ## formats (e.g. `app.yml` + `app.toml`) raises `ConfigError`.
  result = @[]
  if not dirExists(dir):
    return
  for path in walkFiles(dir / "*"):
    let f = path.splitFile
    if f.ext.toLowerAscii in configFileExtensions:
      for prev in result:
        if prev.name == f.name:
          raise newException(ConfigError,
            "Duplicate configuration `" & f.name & "`: `" &
            prev.path & "` and `" & path & "`. " &
            "Use a single format per configuration.")
      result.add((f.name, path, f.ext))
  result.sort(proc(a, b: ConfigEntry): int = cmp(a.name, b.name))

proc loadConfigurations*(dir: string): OrderedTableRef[string, Configuration] =
  ## Loads every configuration file in `dir` natively, stripping each
  ## `static` block. Usable both at runtime and at compile time.
  result = newOrderedTable[string, Configuration]()
  for entry in scanConfigDir(dir):
    var conf = parseConfiguration(entry.ext, readFile(entry.path))
    conf.stripStatic()
    result[entry.name] = ensureMove(conf)

#
# Runtime lookup
#
proc get*(conf: Configuration, key: string): ConfigValue =
  ## Dotted-path lookup inside `conf`, dispatching to the native getter.
  ## Missing keys return a nil node in every format (no raise).
  case conf.format
  of cfgYaml:
    var node: YamlNode = nil
    if conf.yamlDoc != nil:
      try:
        node = conf.yamlDoc.get(key)
      except KeyError:
        node = nil
    ConfigValue(format: cfgYaml, yamlNode: node)
  of cfgToml:
    ConfigValue(format: cfgToml, tomlNode: conf.tomlDoc.get(key))
  of cfgJson:
    var node = conf.jsonDoc
    for part in key.split('.'):
      if node != nil and node.kind == JObject and node.hasKey(part):
        node = node[part]
      else:
        node = nil
        break
    ConfigValue(format: cfgJson, jsonNode: node)

proc isNil*(v: ConfigValue): bool =
  ## Whether the lookup produced no node.
  case v.format
  of cfgYaml: v.yamlNode.isNil
  of cfgToml: v.tomlNode.isNil
  of cfgJson: v.jsonNode.isNil

proc getStr*(v: ConfigValue): string =
  ## String value, or `""` on mismatch/missing.
  case v.format
  of cfgYaml: v.yamlNode.getStr
  of cfgToml: v.tomlNode.getStr
  of cfgJson:
    if v.jsonNode != nil: v.jsonNode.getStr else: ""

proc getInt*(v: ConfigValue): int64 =
  ## Integer value, or `0` on mismatch/missing.
  case v.format
  of cfgYaml: v.yamlNode.getInt
  of cfgToml: v.tomlNode.getInt
  of cfgJson:
    if v.jsonNode != nil: v.jsonNode.getBiggestInt else: 0

proc getFloat*(v: ConfigValue): float64 =
  ## Float value, or `0.0` on mismatch/missing.
  case v.format
  of cfgYaml: v.yamlNode.getFloat
  of cfgToml: v.tomlNode.getFloat
  of cfgJson:
    if v.jsonNode.isNil:
      0.0
    elif v.jsonNode.kind == JFloat:
      v.jsonNode.getFloat
    elif v.jsonNode.kind == JInt:
      v.jsonNode.getBiggestInt.float64
    else:
      0.0

proc getBool*(v: ConfigValue): bool =
  ## Boolean value, or `false` on mismatch/missing.
  case v.format
  of cfgYaml: v.yamlNode.getBool
  of cfgToml: v.tomlNode.getBool
  of cfgJson:
    if v.jsonNode != nil: v.jsonNode.getBool else: false

#
# Runtime mutation (native per format)
#
proc putStr*(conf: var Configuration, key, val: string) =
  ## Sets `key` to `val` in `conf`, natively per format.
  case conf.format
  of cfgYaml:
    conf.yamlDoc[key] = newYamlString(val)
  of cfgToml:
    if conf.tomlDoc.isNil or conf.tomlDoc.kind != tvkTable:
      raise newException(ConfigError, "Cannot set `" & key & "`: not a table document.")
    conf.tomlDoc.tableVal[key] = newTomlString(val)
  of cfgJson:
    if conf.jsonDoc.isNil or conf.jsonDoc.kind != JObject:
      raise newException(ConfigError, "Cannot set `" & key & "`: not an object document.")
    conf.jsonDoc[key] = newJString(val)

proc putInt*(conf: var Configuration, key: string, val: int64) =
  ## Sets `key` to `val` in `conf`, natively per format.
  case conf.format
  of cfgYaml:
    conf.yamlDoc[key] = newYamlInteger(val)
  of cfgToml:
    if conf.tomlDoc.isNil or conf.tomlDoc.kind != tvkTable:
      raise newException(ConfigError, "Cannot set `" & key & "`: not a table document.")
    conf.tomlDoc.tableVal[key] = newTomlInteger(val)
  of cfgJson:
    if conf.jsonDoc.isNil or conf.jsonDoc.kind != JObject:
      raise newException(ConfigError, "Cannot set `" & key & "`: not an object document.")
    conf.jsonDoc[key] = newJInt(val)

proc putFloat*(conf: var Configuration, key: string, val: float64) =
  ## Sets `key` to `val` in `conf`, natively per format.
  case conf.format
  of cfgYaml:
    conf.yamlDoc[key] = newYamlFloat(val)
  of cfgToml:
    if conf.tomlDoc.isNil or conf.tomlDoc.kind != tvkTable:
      raise newException(ConfigError, "Cannot set `" & key & "`: not a table document.")
    conf.tomlDoc.tableVal[key] = newTomlFloat(val)
  of cfgJson:
    if conf.jsonDoc.isNil or conf.jsonDoc.kind != JObject:
      raise newException(ConfigError, "Cannot set `" & key & "`: not an object document.")
    conf.jsonDoc[key] = newJFloat(val)

proc putBool*(conf: var Configuration, key: string, val: bool) =
  ## Sets `key` to `val` in `conf`, natively per format.
  case conf.format
  of cfgYaml:
    conf.yamlDoc[key] = newYamlBoolean(val)
  of cfgToml:
    if conf.tomlDoc.isNil or conf.tomlDoc.kind != tvkTable:
      raise newException(ConfigError, "Cannot set `" & key & "`: not a table document.")
    conf.tomlDoc.tableVal[key] = newTomlBoolean(val)
  of cfgJson:
    if conf.jsonDoc.isNil or conf.jsonDoc.kind != JObject:
      raise newException(ConfigError, "Cannot set `" & key & "`: not an object document.")
    conf.jsonDoc[key] = newJBool(val)

#
# Compile-time `static` configuration
#
var staticConfigsStore {.compileTime.}: OrderedTable[string, OrderedTable[string, Configuration]]
  ## Compile-time-only singleton holding every parsed configuration
  ## document per directory, `static` blocks included. It does not
  ## exist at runtime.

proc parseConfigurationStatic(ext, content: string): Configuration {.compileTime.} =
  ## Compile-time twin of `parseConfiguration`, producing the same native
  ## `Configuration` model. JSON goes through `std/json`'s `parseJson`
  ## (re-exported by `openparser/json`) because openparser's own JSON
  ## lexer is pointer/SIMD-based and cannot run in the NimVM.
  let format = formatForExt(ext)
  try:
    case format
    of cfgYaml:
      result = Configuration(format: cfgYaml, yamlDoc: parseYAML(content))
    of cfgToml:
      result = Configuration(format: cfgToml, tomlDoc: parseTOML(content))
    of cfgJson:
      result = Configuration(format: cfgJson, jsonDoc: parseJson(content))
  except ConfigError:
    raise
  except CatchableError as e:
    raise newException(ConfigError, e.msg)

proc ensureStaticFile(dir, file: string) {.compileTime.} =
  ## Lazily parses `file` (probing `.yml`/`.yaml`, `.toml`, `.json`)
  ## into `staticConfigsStore[dir]`, keeping its `static` block.
  ## `walkFiles` cannot run in the VM, so candidates are probed with
  ## `fileExists` instead. Unknown files and base-name collisions
  ## across formats raise `ConfigError`.
  if staticConfigsStore.hasKey(dir) and staticConfigsStore[dir].hasKey(file):
    return
  var hits: seq[ConfigEntry] = @[]
  for ext in configFileExtensions:
    let path = dir / file & ext
    try:
      if fileExists(path):
        hits.add((file, path, ext))
    except CatchableError:
      discard
  if hits.len == 0:
    raise newException(ConfigError,
      "Unknown static configuration file `" & file & "` in `" & dir & "`.")
  if hits.len > 1:
    raise newException(ConfigError,
      "Duplicate static configuration `" & file & "`: `" &
      hits[0].path & "` and `" & hits[1].path & "`. " &
      "Use a single format per configuration.")
  try:
    staticConfigsStore.mgetOrPut(dir,
      initOrderedTable[string, Configuration]())[file] =
        parseConfigurationStatic(hits[0].ext, staticRead(hits[0].path))
  except ConfigError as e:
    raise newException(ConfigError,
      "Invalid static configuration `" & hits[0].path & "`: " & e.msg)

proc staticNodeError(key: string): ref ConfigError {.compileTime.} =
  newException(ConfigError,
    "Invalid static key `" & key & "`. Expected `file.key.path` " &
    "pointing inside a top-level `static` mapping.")

proc yamlStaticValue[T](n: YamlNode, v: var T, path: string) {.compileTime.} =
  ## Converts a YAML node from a `static` block into `T`.
  when T is YamlNode:
    v = n
  elif T is string:
    if n == nil or n.kind != yamlString:
      raise newException(ConfigError, "Expected a string at `" & path & "`")
    v = n.strValue
  elif T is bool:
    if n == nil or n.kind != yamlBoolean:
      raise newException(ConfigError, "Expected a boolean at `" & path & "`")
    v = n.boolValue
  elif T is SomeInteger:
    if n == nil or n.kind != yamlInteger:
      raise newException(ConfigError, "Expected an integer at `" & path & "`")
    v = T(n.intValue)
  elif T is SomeFloat:
    if n == nil:
      raise newException(ConfigError, "Expected a float at `" & path & "`")
    case n.kind
    of yamlFloat: v = T(n.floatValue)
    of yamlInteger: v = T(n.intValue)
    else:
      raise newException(ConfigError, "Expected a float at `" & path & "`")
  elif T is seq:
    if n == nil or n.kind != yamlArray:
      raise newException(ConfigError, "Expected an array at `" & path & "`")
    v.setLen(0)
    for i, item in n.arrValue:
      var e: typeof(v[0])
      yamlStaticValue(item, e, path & "[" & $i & "]")
      v.add(ensureMove(e))
  elif T is (object or tuple):
    if n == nil or n.kind != yamlObject:
      raise newException(ConfigError, "Expected an object at `" & path & "`")
    for fieldName, fieldVal in v.fieldPairs:
      if n.objValue.hasKey(fieldName):
        yamlStaticValue(n.objValue[fieldName], fieldVal, path & "." & fieldName)
  elif T is (ref object):
    if n == nil or n.kind != yamlObject:
      raise newException(ConfigError, "Expected an object at `" & path & "`")
    if v.isNil:
      new(v)
    for fieldName, fieldVal in v[].fieldPairs:
      if n.objValue.hasKey(fieldName):
        yamlStaticValue(n.objValue[fieldName], fieldVal, path & "." & fieldName)
  else:
    {.error: "staticConfig: unsupported static type".}

proc tomlStaticValue[T](n: TomlNode, v: var T, path: string) {.compileTime.} =
  ## Converts a TOML node from a `static` block into `T`.
  when T is TomlNode:
    v = n
  elif T is string:
    if n == nil or n.kind != tvkString:
      raise newException(ConfigError, "Expected a string at `" & path & "`")
    v = n.strVal
  elif T is bool:
    if n == nil or n.kind != tvkBoolean:
      raise newException(ConfigError, "Expected a boolean at `" & path & "`")
    v = n.boolVal
  elif T is SomeInteger:
    if n == nil or n.kind != tvkInteger:
      raise newException(ConfigError, "Expected an integer at `" & path & "`")
    try:
      v = T(n.intVal)
    except RangeDefect:
      raise newException(ConfigError, "Integer out of range at `" & path & "`")
  elif T is SomeFloat:
    if n == nil:
      raise newException(ConfigError, "Expected a float at `" & path & "`")
    case n.kind
    of tvkFloat: v = T(n.floatVal)
    of tvkInteger: v = T(n.intVal)
    else:
      raise newException(ConfigError, "Expected a float at `" & path & "`")
  elif T is seq:
    if n == nil or n.kind != tvkArray:
      raise newException(ConfigError, "Expected an array at `" & path & "`")
    v.setLen(0)
    for i, item in n.arrayVal:
      var e: typeof(v[0])
      tomlStaticValue(item, e, path & "[" & $i & "]")
      v.add(ensureMove(e))
  elif T is (object or tuple):
    if n == nil or n.kind != tvkTable:
      raise newException(ConfigError, "Expected a table at `" & path & "`")
    for fieldName, fieldVal in v.fieldPairs:
      if n.tableVal.hasKey(fieldName):
        tomlStaticValue(n.tableVal[fieldName], fieldVal, path & "." & fieldName)
  elif T is (ref object):
    if n == nil or n.kind != tvkTable:
      raise newException(ConfigError, "Expected a table at `" & path & "`")
    if v.isNil:
      new(v)
    for fieldName, fieldVal in v[].fieldPairs:
      if n.tableVal.hasKey(fieldName):
        tomlStaticValue(n.tableVal[fieldName], fieldVal, path & "." & fieldName)
  else:
    {.error: "staticConfig: unsupported static type".}

proc jsonStaticValue[T](n: JsonNode, v: var T, path: string) {.compileTime.} =
  ## Converts a JSON node from a `static` block into `T`.
  when T is JsonNode:
    v = n
  elif T is string:
    if n == nil or n.kind != JString:
      raise newException(ConfigError, "Expected a string at `" & path & "`")
    v = n.getStr
  elif T is bool:
    if n == nil or n.kind != JBool:
      raise newException(ConfigError, "Expected a boolean at `" & path & "`")
    v = n.getBool
  elif T is SomeInteger:
    if n == nil or n.kind != JInt:
      raise newException(ConfigError, "Expected an integer at `" & path & "`")
    try:
      v = T(n.getBiggestInt)
    except RangeDefect:
      raise newException(ConfigError, "Integer out of range at `" & path & "`")
  elif T is SomeFloat:
    if n == nil:
      raise newException(ConfigError, "Expected a float at `" & path & "`")
    case n.kind
    of JFloat: v = T(n.getFloat)
    of JInt: v = T(n.getBiggestInt)
    else:
      raise newException(ConfigError, "Expected a float at `" & path & "`")
  elif T is seq:
    if n == nil or n.kind != JArray:
      raise newException(ConfigError, "Expected an array at `" & path & "`")
    v.setLen(0)
    for i, item in n.elems:
      var e: typeof(v[0])
      jsonStaticValue(item, e, path & "[" & $i & "]")
      v.add(ensureMove(e))
  elif T is (object or tuple):
    if n == nil or n.kind != JObject:
      raise newException(ConfigError, "Expected an object at `" & path & "`")
    for fieldName, fieldVal in v.fieldPairs:
      if n.hasKey(fieldName):
        jsonStaticValue(n[fieldName], fieldVal, path & "." & fieldName)
  elif T is (ref object):
    if n == nil or n.kind != JObject:
      raise newException(ConfigError, "Expected an object at `" & path & "`")
    if v.isNil:
      new(v)
    for fieldName, fieldVal in v[].fieldPairs:
      if n.hasKey(fieldName):
        jsonStaticValue(n[fieldName], fieldVal, path & "." & fieldName)
  else:
    {.error: "staticConfig: unsupported static type".}

proc staticConfigImpl[T](dir, key: string): T {.compileTime.} =
  ## Resolves `file.key.path` against the compile-time store for `dir`
  ## and converts the node found inside the file's `static` block to `T`.
  let dotIdx = key.find('.')
  if dotIdx <= 0 or dotIdx == key.len - 1:
    raise staticNodeError(key)
  let
    file = key[0 ..< dotIdx]
    rest = key[dotIdx + 1 .. ^1]
  ensureStaticFile(dir, file)
  if not staticConfigsStore[dir].hasKey(file):
    raise newException(ConfigError,
      "Unknown static configuration file `" & file & "` in `" & key & "`.")
  let conf = staticConfigsStore[dir][file]
  case conf.format
  of cfgYaml:
    if not conf.yamlDoc.hasKey("static") or
        conf.yamlDoc.get("static").kind != yamlObject:
      raise newException(ConfigError,
        "Configuration `" & file & "` has no top-level `static` mapping.")
    let node = conf.yamlDoc.get("static").get(rest)
    if node.isNil:
      raise newException(ConfigError,
        "Unknown static key `" & rest & "` in `" & file & "`.")
    yamlStaticValue(node, result, key)
  of cfgToml:
    if not conf.tomlDoc.tableVal.hasKey("static") or
        conf.tomlDoc.tableVal["static"].kind != tvkTable:
      raise newException(ConfigError,
        "Configuration `" & file & "` has no top-level `static` table.")
    let node = conf.tomlDoc.tableVal["static"].get(rest)
    if node.isNil:
      raise newException(ConfigError,
        "Unknown static key `" & rest & "` in `" & file & "`.")
    tomlStaticValue(node, result, key)
  of cfgJson:
    if not conf.jsonDoc.hasKey("static") or
        conf.jsonDoc["static"].kind != JObject:
      raise newException(ConfigError,
        "Configuration `" & file & "` has no top-level `static` object.")
    var node = conf.jsonDoc["static"]
    for part in rest.split('.'):
      if node != nil and node.kind == JObject and node.hasKey(part):
        node = node[part]
      else:
        node = nil
        break
    if node.isNil:
      raise newException(ConfigError,
        "Unknown static key `" & rest & "` in `" & file & "`.")
    jsonStaticValue(node, result, key)

proc staticConfig*[T](key: string): T {.compileTime.} =
  ## Reads a compile-time setting from a configuration file's top-level
  ## `static` block. `key` has the shape `file.key.path`, resolved against
  ## the application's compile-time `config/` directory:
  ##
  ## .. code-block:: nim
  ##   const debug = staticConfig[bool]("app.debug")
  ##   when staticConfig[bool]("app.enable_feature"):
  ##     ...
  ##
  ## Plain Nim types only (`string`, integers, floats, `bool`, `seq`,
  ## objects, tuples). Unknown files, missing `static` blocks, missing
  ## keys and type mismatches are compile errors.
  staticConfigImpl[T](configPath, key)

proc staticConfigFromDir*[T](dir, key: string): T {.compileTime.} =
  ## Same as `staticConfig`, resolved against `dir` instead of the
  ## application's `config/` directory. Used for fixture-based tests.
  staticConfigImpl[T](dir, key)
