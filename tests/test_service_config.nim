#
# Unit tests for the `initService` compile-time config installer
# (supranim/core/services) and the cookie secure-context helpers.
#
import std/unittest
import std/[os, options, tables, strutils]
import std/cookies except `$`

import supranim/core/services
import supranim/support/cookie
import supranim/core/paths

# Importing the fixture provider expands `initService`, which installs
# `config/probe_fakesvc_install.yml` into the app `config/` directory
# (here: tests/config/) at compile time.
import fixtures/fakesvc/src/fakesvc/service/svc

const probeBase = "probe_fakesvc_install"

suite "Service config format conversion":
  test "normalizeServiceConfigExt":
    check normalizeServiceConfigExt(".yml") == ".yml"
    check normalizeServiceConfigExt(".YAML") == ".yml"
    check normalizeServiceConfigExt(".toml") == ".toml"
    check normalizeServiceConfigExt(".json") == ".json"
    check normalizeServiceConfigExt(".ini") == ""

  test "yaml parses into the json intermediate":
    let doc = parseServiceConfig("a: 1\nb: hello\nc: true\nd: 1.5\n", ".yml")
    check doc["a"].getBiggestInt == 1
    check doc["b"].getStr == "hello"
    check doc["c"].getBool == true
    check doc["d"].getFloat == 1.5

  test "toml parses into the json intermediate":
    let doc = parseServiceConfig("a = 1\nb = \"hello\"\nc = true\n", ".toml")
    check doc["a"].getBiggestInt == 1
    check doc["b"].getStr == "hello"
    check doc["c"].getBool == true

  test "json parses into the json intermediate":
    let doc = parseServiceConfig("""{"a": 1, "b": "hi"}""", ".json")
    check doc["a"].getBiggestInt == 1
    check doc["b"].getStr == "hi"

  test "yaml -> toml -> yaml roundtrip preserves values":
    let src = "greeting: hello\nport: 4321\nnested:\n  enabled: true\n  ratio: 1.5\n  tags:\n    - a\n    - b\n"
    let tomlText = dumpServiceConfig(parseServiceConfig(src, ".yml"), ".toml")
    check "greeting = \"hello\"" in tomlText
    let back = parseServiceConfig(tomlText, ".toml")
    check back["greeting"].getStr == "hello"
    check back["port"].getBiggestInt == 4321
    check back["nested"]["enabled"].getBool == true
    check back["nested"]["ratio"].getFloat == 1.5
    check back["nested"]["tags"][1].getStr == "b"
    # and back to yaml again
    let yamlText = dumpServiceConfig(back, ".yml")
    let back2 = parseServiceConfig(yamlText, ".yml")
    check back2["nested"]["tags"][0].getStr == "a"

  test "yaml -> json roundtrip preserves values":
    let src = "port: 4321\nenabled: false\n"
    let jsonText = dumpServiceConfig(parseServiceConfig(src, ".yml"), ".json")
    let back = parseServiceConfig(jsonText, ".json")
    check back["port"].getBiggestInt == 4321
    check back["enabled"].getBool == false

  test "detectAppConfigFormat by plurality, yaml default":
    let dir = getTempDir() / "svc_cfg_pref"
    if dirExists(dir): removeDir(dir)
    createDir(dir)
    check detectAppConfigFormat(dir) == ".yml"
    writeFile(dir / "a.toml", "x = 1\n")
    writeFile(dir / "b.toml", "y = 2\n")
    writeFile(dir / "c.yml", "z: 3\n")
    check detectAppConfigFormat(dir) == ".toml"
    writeFile(dir / "d.json", "{}\n")
    writeFile(dir / "e.json", "{}\n")
    writeFile(dir / "f.json", "{}\n")
    check detectAppConfigFormat(dir) == ".json"
    removeDir(dir)
    check detectAppConfigFormat(dir / "missing") == ".yml"

  test "providerPackageRoot finds the enclosing nimble package":
    let root = getTempDir() / "svc_pkg_root"
    if dirExists(root): removeDir(root)
    createDir(root / "src" / "pkg" / "service")
    writeFile(root / "pkg.nimble", "version = \"0.0.1\"\n")
    let svc = root / "src" / "pkg" / "service" / "svc.nim"
    writeFile(svc, "discard\n")
    check providerPackageRoot(svc) == root
    removeDir(root)

  test "providerConfigDir finds config with supported files":
    let root = getTempDir() / "svc_cfg_dir"
    if dirExists(root): removeDir(root)
    createDir(root / "src" / "pkg" / "service")
    createDir(root / "config")
    writeFile(root / "pkg.nimble", "version = \"0.0.1\"\n")
    writeFile(root / "config" / "s.yml", "a: 1\n")
    let svc = root / "src" / "pkg" / "service" / "svc.nim"
    writeFile(svc, "discard\n")
    check providerConfigDir(svc, root) == root / "config"
    # a tree without any supported config file yields ""
    let emptyRoot = getTempDir() / "svc_cfg_empty"
    if dirExists(emptyRoot): removeDir(emptyRoot)
    createDir(emptyRoot / "src" / "pkg" / "service")
    writeFile(emptyRoot / "pkg.nimble", "version = \"0.0.1\"\n")
    writeFile(emptyRoot / "src" / "pkg" / "service" / "svc.nim", "discard\n")
    check providerConfigDir(emptyRoot / "src" / "pkg" / "service" / "svc.nim",
      emptyRoot) == ""
    removeDir(root)
    removeDir(emptyRoot)

suite "Cookie secure-context helpers":
  test "parseSecureMode":
    check parseSecureMode("auto") == secureAuto
    check parseSecureMode("ALWAYS") == secureAlways
    check parseSecureMode("never") == secureNever
    check parseSecureMode("bogus") == secureAuto

  test "isLoopbackHost":
    check isLoopbackHost("localhost")
    check isLoopbackHost("localhost:8080")
    check isLoopbackHost("127.0.0.1")
    check isLoopbackHost("127.0.0.1:3000")
    check isLoopbackHost("127.1.2.3")
    check isLoopbackHost("::1")
    check isLoopbackHost("[::1]:8080")
    check isLoopbackHost("api.localhost")
    check isLoopbackHost("")
    check not isLoopbackHost("example.com")
    check not isLoopbackHost("example.com:8080")
    check not isLoopbackHost("128.0.0.1")

  test "proxy headers resolve the effective scheme only when trusted":
    check effectiveSchemeFromHeaders("https", "", true) == "https"
    check effectiveSchemeFromHeaders("https, http", "", true) == "https"
    check effectiveSchemeFromHeaders("", "for=1.2.3.4;proto=https", true) == "https"
    check effectiveSchemeFromHeaders("https", "", false) == "http"
    check effectiveSchemeFromHeaders("", "for=1.2.3.4;proto=https", false) == "http"
    check effectiveSchemeFromHeaders("", "", true) == "http"

  test "shouldEmitSecureScheme follows auto/always/never":
    check shouldEmitSecureScheme("https", secureAuto)
    check not shouldEmitSecureScheme("http", secureAuto)
    check shouldEmitSecureScheme("http", secureAlways)
    check not shouldEmitSecureScheme("https", secureNever)

suite "initService installs provider config (copy-once)":
  test "fixture provider config is installed (macro hook + copy-once)":
    # Importing the fixture provider above expands `initService`, which
    # installs the probe file at compile time. Test runners may reuse a
    # cached binary whose earlier run already cleaned up; ensure the
    # precondition explicitly so the test is hermetic either way.
    let
      dst = configPath / probeBase & ".yml"
      fixtureSvc = currentSourcePath().parentDir / "fixtures" / "fakesvc" /
        "src" / "fakesvc" / "service" / "svc.nim"
    if not fileExists(dst):
      createDir(configPath)
      installServiceConfigs(fixtureSvc, getTempDir() / "svc_hook_proj", configPath)
    check fileExists(dst)
    let content = readFile(dst)
    check "hello-fixture" in content
    check "port: 4321" in content
    # cleanup so the repo stays pristine; the next compile reinstalls.
    removeFile(dst)
    try:
      removeDir(configPath)
    except OSError:
      discard

  test "copy-once: existing files are never overwritten":
    let sandbox = getTempDir() / "svc_install_once"
    if dirExists(sandbox): removeDir(sandbox)
    let pkgRoot = sandbox / "pkg"
    let appDir = sandbox / "app"
    createDir(pkgRoot / "src" / "pkg" / "service")
    createDir(pkgRoot / "config")
    createDir(appDir)
    writeFile(pkgRoot / "pkg.nimble", "version = \"0.0.1\"\n")
    let svcFile = pkgRoot / "src" / "pkg" / "service" / "svc.nim"
    writeFile(svcFile, "discard\n")
    writeFile(pkgRoot / "config" / "probe.yml", "greeting: hello\nport: 1\n")
    let fakeProject = sandbox / "myapp"
    createDir(fakeProject)
    installServiceConfigs(svcFile, fakeProject, appDir / "config")
    check readFile(appDir / "config" / "probe.yml") == "greeting: hello\nport: 1\n"
    # emulate a user edit, reinstall, and confirm it survives
    writeFile(appDir / "config" / "probe.yml", "greeting: edited\n")
    installServiceConfigs(svcFile, fakeProject, appDir / "config")
    check readFile(appDir / "config" / "probe.yml") == "greeting: edited\n"
    removeDir(sandbox)

  test "toml-preferring apps get converted content":
    let sandbox = getTempDir() / "svc_install_toml"
    if dirExists(sandbox): removeDir(sandbox)
    let pkgRoot = sandbox / "pkg"
    let appConfig = sandbox / "app" / "config"
    createDir(pkgRoot / "src" / "pkg" / "service")
    createDir(pkgRoot / "config")
    createDir(appConfig)
    writeFile(pkgRoot / "pkg.nimble", "version = \"0.0.1\"\n")
    let svcFile = pkgRoot / "src" / "pkg" / "service" / "svc.nim"
    writeFile(svcFile, "discard\n")
    writeFile(pkgRoot / "config" / "probe.yml",
      "greeting: hello\nport: 4321\nnested:\n  enabled: true\n")
    writeFile(appConfig / "app.toml", "port = 8080\n")
    let fakeProject = sandbox / "myapp"
    createDir(fakeProject)
    installServiceConfigs(svcFile, fakeProject, appConfig)
    check not fileExists(appConfig / "probe.yml")
    check fileExists(appConfig / "probe.toml")
    let back = parseServiceConfig(readFile(appConfig / "probe.toml"), ".toml")
    check back["greeting"].getStr == "hello"
    check back["port"].getBiggestInt == 4321
    check back["nested"]["enabled"].getBool == true
    # app's own files are untouched
    check readFile(appConfig / "app.toml") == "port = 8080\n"
    removeDir(sandbox)

  test "self-builds install nothing":
    let sandbox = getTempDir() / "svc_install_self"
    if dirExists(sandbox): removeDir(sandbox)
    let pkgRoot = sandbox / "pkg"
    createDir(pkgRoot / "src" / "pkg" / "service")
    createDir(pkgRoot / "config")
    writeFile(pkgRoot / "pkg.nimble", "version = \"0.0.1\"\n")
    let svcFile = pkgRoot / "src" / "pkg" / "service" / "svc.nim"
    writeFile(svcFile, "discard\n")
    writeFile(pkgRoot / "config" / "probe.yml", "a: 1\n")
    # project dir inside the provider package: no install anywhere
    installServiceConfigs(svcFile, pkgRoot / "src", sandbox / "out")
    check not dirExists(sandbox / "out")
    removeDir(sandbox)
