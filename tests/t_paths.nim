#
# Unit tests for supranim/core/paths
#
import std/unittest
import std/[os, strutils]

import supranim/core/paths

proc setupDir(): string =
  result = getTempDir() / "supranim_paths_test_" & $(getCurrentProcessId())
  createDir(result)
  result = expandFilename(result)

suite "ApplicationPaths":
  test "basePath and rootPath constants are set":
    check basePath.len > 0
    check rootPath.len > 0
    check basePath.startsWith("/")

  test "init with an existing dir and createDirs":
    let dir = setupDir()
    defer: removeDir(dir)
    var p = ApplicationPaths()
    check p.init(dir, createDirs = true)
    check p.getInstallationPath == dir
    check dirExists(dir / "storage")
    check dirExists(dir / "storage" / "plugins")
    check dirExists(dir / "storage" / "templates")
    check dirExists(dir / "storage" / "logs")
    check dirExists(dir / "storage" / "public")

  test "init without createDirs does not create dirs":
    let dir = setupDir()
    defer: removeDir(dir)
    var p = ApplicationPaths()
    check p.init(dir, createDirs = false)
    check not dirExists(dir / "storage")

  test "resolve joins the install path with dir and file":
    let dir = setupDir()
    defer: removeDir(dir)
    var p = ApplicationPaths()
    check p.init(dir, createDirs = false)
    check p.resolve("storage") == dir / "storage"
    check p.resolve("storage", "uploads/avatar.png") == dir / "storage" / "uploads/avatar.png"
