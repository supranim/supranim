#
# Full-app smoke test: scaffold a real Supranim app with the `supra` CLI,
# point it at this local source, build it with the powpow backend, boot it
# against an embedded Postgres (pkg/greskewel), and probe it over HTTP.
#
# Run explicitly with `nim c -r` (excluded from `nimble test`):
#   nim c -r -d:features.supranim.powpow \
#       --path:/Users/georgelemon/Development/otherpackages/embedded-postgres/src \
#       tests/smoke_app.nim
#
# The `--path` above points `pkg/greskewel` at the local development source of
# the embedded Postgres box so the two projects can be debugged together.
#
# Requires: `supra` CLI on PATH, network access (starterkit download + the
# first-time Postgres binary download into tests/data), and nimble deps.
#
import std/unittest
import std/[os, osproc, net, strutils, times, httpcore, tables]

import pkg/greskewel
import pkg/chopchop

import helpers

const RepoRoot = parentDir(parentDir(currentSourcePath()))
const PgVersion = "16.9.0"

# greskewel stores its downloaded binaries under <basePath>/bin/<version>/<os>
const OsDir =
  when defined(macosx): "darwin"
  elif defined(linux): "linux"
  else: "windows"
const LibPqName =
  when defined(macosx): "libpq.dylib"
  elif defined(linux): "libpq.so"
  else: "libpq.dll"

var
  gPg: EmbeddedPostgres
  gPgStarted = false
  gAppProc: Process
  gWorkDir = ""

proc cleanupSmoke() {.noconv.} =
  ## Runs on every exit path (addQuitProc), guaranteeing the embedded
  ## Postgres server and the booted app are stopped — they would otherwise
  ## leak as orphan processes.
  if gAppProc != nil:
    gAppProc.terminate()
    discard gAppProc.waitForExit(5_000)
  if gPgStarted:
    gPg.stop()
    gPg.dispose()
  if gWorkDir.len > 0:
    removeDir(gWorkDir)

proc writeFileUnless(dir, name, content: string) =
  let dir = dir / name
  createDir(dir.parentDir)
  writeFile(dir, content)

proc replaceInFile(path, fromText, toText: string): bool =
  if not fileExists(path):
    return false
  var content = readFile(path)
  if fromText notin content:
    return false
  content = content.replace(fromText, toText)
  writeFile(path, content)
  true

suite "Full-app smoke (supra + embedded postgres + powpow)":
  test "scaffold, build and boot a Supranim app end-to-end":
    # stdout is fully buffered when piped (not a TTY); make progress visible.
    setStdIoUnbuffered()
    addQuitProc(cleanupSmoke)

    check findExe("supra").len > 0

    gWorkDir = tempDir("supranim_smoke_")
    let
      workDir = gWorkDir
      pgPort = Port(5432)
      appPort = Port(3000)
      appDir = workDir / "testapp"

    # ---------- 1. embedded Postgres -------------------------------------
    # Binaries are cached in tests/data (download once); the Postgres data
    # directory is per-run so concurrent or failed runs never collide.
    # NOTE: greskewel joins `basePath / dataPath`, so dataPath must be
    # relative to stay inside tests/data.
    let pgBase = RepoRoot / "tests" / "data"
    createDir(pgBase)
    gPg = initEmbeddedPostgres(PostgresConfig(
      basePath: pgBase,
      port: pgPort,
      dataPath: "run_" & $(getCurrentProcessId()) & "_data"
    ))
    gPg.downloadBinaries()
    gPg.init()
    gPg.start()
    gPgStarted = true
    # greskewel's `start` already waits ~3s internally; give postgres a moment
    # to accept connections before the app connects to it.
    sleep(2000)
    check gPg.isRunning()
    # libpq bundled with the embedded Postgres — the app's DB driver
    # (pkg/db_connector) must be pointed at it via a `dynlib` push, otherwise
    # it looks for libpq in the global loader path and fails.
    let libPqPath = pgBase / "bin" / PgVersion / OsDir / "lib" / LibPqName
    check fileExists(libPqPath)

    # ---------- 2. scaffold the app with the supra CLI -------------------
    let initRes = execCmdEx("supra init testapp --skipconfig", workingDir = workDir)
    if initRes.exitCode != 0:
      echo "\n----- supra init output (tail) -----\n",
           initRes.output.splitLines[^20..^1].join("\n")
    check initRes.exitCode == 0
    check dirExists(appDir)

    # ---------- 3. point the app at the embedded postgres ----------------
    let envYml =
      "database:\n" &
      "  type: postgres\n" &
      "  local:\n" &
      "    address: \"127.0.0.1\"\n" &
      "    user: \"postgres\"\n" &
      "    name: \"postgres\"\n" &
      "    password: \"postgres\"\n" &
      # NOTE: must be a string — openparser `getStr` returns "" for an int
      "    port: \"" & $pgPort.int & "\"\n" &
      "  prod:\n" &
      "    address: \"127.0.0.1\"\n" &
      "    user: \"postgres\"\n" &
      "    name: \"postgres\"\n" &
      "    password: \"postgres\"\n" &
      "    port: \"" & $pgPort.int & "\"\n"
    writeFile(appDir / ".env.yml", envYml)

    # ---------- 4. run the app on a free port ----------------------------
    writeFileUnless(appDir, "src/config/server.yml",
      "address: \"127.0.0.1\"\nport: " & $appPort.int & "\nthreads: 1\ntype: AF_INET\n")

    # ---------- 5. use this local supranim source ------------------------
    writeFileUnless(appDir, "config.nims",
      "switch(\"path\", \"" & RepoRoot / "src" & "\")\n")

    # ---------- 6. force the powpow backend + threaded server ------------
    writeFile(appDir / "src" / "app.nims",
      "--deepCopy:on\n--mm:atomicArc\n--threads:on\n" &
      "--define:webapp\n--define:supraFileserver\n" &
      "--define:features.supranim.powpow\n")

    # ---------- 7. patch the DB service -----------------------------------
    let dbNim = appDir / "src" / "service" / "provider" / "db.nim"
    # 7a. read the postgres port from the environment
    check replaceInFile(dbNim,
      "import std/[strutils, tables, times, macros, os]",
      "import std/[strutils, tables, times, macros, os, net]")
    check replaceInFile(dbNim,
      "password = getEnv(\"database.password\")\n        )",
      "password = getEnv(\"database.password\"),\n          port = Port(parseInt(getEnv(\"database.port\")))\n        )")
    # 7b. bind the DB driver to the bundled libpq
    check replaceInFile(dbNim,
      "initService DB[Global]:",
      "{.push dynlib: \"" & libPqPath & "\".}\ninitService DB[Global]:")

    # ---------- 8. build ---------------------------------------------------
    let buildRes = execCmdEx("nimble build --features:powpow",
      workingDir = appDir)
    echo "\n----- nimble build output -----\n"
    echo buildRes.output
    
    check buildRes.exitCode == 0
    let binPath = appDir / "build" / "testapp"
    check fileExists(binPath)

    # ---------- 9. boot the app --------------------------------------------
    # The starterkit build copies `src/config` into `build/config`, so the
    # app must be run from the build dir (`./testapp start .`) for the
    # configuration files to be discovered relative to the CWD.
    gAppProc = startProcess(binPath, appDir / "build",
      @["start", appDir / "build"], options = {poUsePath, poStdErrToStdOut})

    # ---------- 10. probe the app -------------------------------------------
    # The first request retries until the app accepts connections.
    let base = "http://127.0.0.1:" & $appPort.int
    let home = httpGetRetry(base & "/", attempts = 60, intervalMs = 1000)
    check home.code in {Http200, Http302}
    check home.body.len > 0

    let login = httpGet(base & "/auth/login")
    check login.code in {Http200, Http302}

    let missing = httpGet(base & "/definitely-not-a-route")
    check missing.code == Http404
