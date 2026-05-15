#
# Supranim is a high-performance web framework for building
# web applications and microservices in Nim
# 
#   (c) 2026 LGPL-v3-or-later License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#
## This module implements a flexible filesystem abstraction layer for Supranim,
## allowing you to manage files across different storage backends (like local disk, cloud storage, etc.)
## using a consistent API.
## 
## The `Filesystem` type provides a multi-disk abstraction where you can define multiple "disks"
## (storage backends) and perform file operations on them using a unified interface.
## 
## The `StorageDriver` type is an abstract base for different storage implementations,
## and the `LocalDriver` is a concrete implementation that interacts with the local filesystem.
## 
## The `Visibility` enum defines file visibility options (public or private), which can be used to
## set permissions or access controls depending on the storage backend.

import std/[macros, os, memfiles, strutils,
            tables, options, times]

import pkg/openparser/[json, yaml, toml]

type        
  Visibility* = enum
    ## Defines file visibility options for storage operations. This can be used
    ## to set permissions or access controls
    visPublic = "public"
    visPrivate = "private"

  FileMetadata* = object
    ## Metadata for a file or directory, including its path, size, last modified time,
    ## visibility, and whether it's a directory. This is returned by the `metadata` method
    ## and the `list` method of storage drivers to provide information about files and directories
    path*: string
    size*: int64
    lastModified*: Time
    visibility*: Visibility
    isDir*: bool

#
# Driver abstraction
#
type
  StorageDriver* = ref object of RootObj
    ## The StorageDriver type is an abstract base for different storage implementations.
    ## Concrete drivers (like LocalDriver) will implement the required file operations
    root*: string

  LocalDriver* = ref object of StorageDriver
    ## Filesystem driver using an absolute runtime root.
    ## The root is set at runtime (from config/env), NOT at compile time.

  StorageError* = object of CatchableError

macro abstract*(x: untyped): untyped =
  ## Macro-based pragma to mark methods as abstract (not implemented in the base driver).
  x[^3] = nnkPragma.newTree(ident"base")
  var body = newStmtList()
  add body, quote do:
    raise newException(StorageError, "Not implemented")
  x[^1] = body
  x

#
# Abstract methods that all drivers must implement
#
method write*(d: StorageDriver, path, content: string, visibility = visPrivate) {.abstract.}
method read*(d: StorageDriver, path: string): string {.abstract.}
method readStream*(d: StorageDriver, path: string): MemFile {.abstract.}
method delete*(d: StorageDriver, path: string) {.abstract.}
method exists*(d: StorageDriver, path: string): bool {.abstract.}
method list*(d: StorageDriver, path: string, recursive = false): seq[FileMetadata] {.abstract.}
method move*(d: StorageDriver, src, dest: string) {.abstract.}
method copy*(d: StorageDriver, src, dest: string) {.abstract.}
method makeDir*(d: StorageDriver, path: string) {.abstract.}
method deleteDir*(d: StorageDriver, path: string) {.abstract.}
method setVisibility*(d: StorageDriver, path: string, visibility: Visibility) {.abstract.}
method metadata*(d: StorageDriver, path: string): FileMetadata {.abstract.}

#
# Local Driver implementation
#
proc resolvePath(d: LocalDriver, path: string): string =
  ## Resolves a relative path against the runtime root.
  ## 
  ## Prevents path traversal outside the root for security
  let resolved = normalizedPath(d.root / path)
  if not resolved.startsWith(d.root):
    # prevent path traversal outside the root
    raise newException(StorageError, "Path traversal detected: " & path)
  resolved

proc newLocalDriver*(root: string): LocalDriver =
  ## Creates a LocalDriver. `root` is an absolute runtime path.
  ## Example: pass in the value of an env var or config key at startup.
  result = LocalDriver(root: expandTilde(root).absolutePath)
  if not dirExists(result.root):
    createDir(result.root)

method write*(d: LocalDriver, path, content: string,
    visibility = visPrivate) =
  let full = d.resolvePath(path)
  createDir(full.parentDir)
  writeFile(full, content)
  # when defined(posix):
  #   import std/posix
  #   let mode = if visibility == visPublic: 0o644 else: 0o600
  #   discard chmod(full.cstring, Mode(mode))

method read*(d: LocalDriver, path: string): string =
  readFile(d.resolvePath(path))

method readStream*(d: LocalDriver, path: string): MemFile =
  memfiles.open(d.resolvePath(path), fmRead)

method delete*(d: LocalDriver, path: string) =
  removeFile(d.resolvePath(path))

method exists*(d: LocalDriver, path: string): bool =
  let full = d.resolvePath(path)
  fileExists(full) or dirExists(full)

method list*(d: LocalDriver, path: string,
    recursive: static bool = false): seq[FileMetadata] =
  let full = d.resolvePath(path)
  when recursive:
    for entry in walkDirRec(full):
      let p = entry
      result.add FileMetadata(path: p.relativePath(d.root),
        size: getFileSize(p), lastModified: getLastModificationTime(p),
        isDir: dirExists(p))
  else:
    for entry in walkDir(full):
      result.add FileMetadata(path: entry.path.relativePath(d.root),
        size: (if entry.kind == pcFile: getFileSize(entry.path) else: 0),
        lastModified: getLastModificationTime(entry.path),
        isDir: entry.kind in {pcDir, pcLinkToDir})

method move*(d: LocalDriver, src, dest: string) =
  moveFile(d.resolvePath(src), d.resolvePath(dest))

method copy*(d: LocalDriver, src, dest: string) =
  ## Copies a file from `src` to `dest` on the local filesystem. Creates parent directories if needed.
  let destFull = d.resolvePath(dest)
  createDir(destFull.parentDir)
  copyFile(d.resolvePath(src), destFull)

method makeDir*(d: LocalDriver, path: string) =
  ## Creates a directory at the specified path. Creates parent directories if needed.
  createDir(d.resolvePath(path))

method deleteDir*(d: LocalDriver, path: string) =
  ## Deletes a directory at the specified path. Deletes recursively if the directory is not empty.
  removeDir(d.resolvePath(path))

method metadata*(d: LocalDriver, path: string): FileMetadata =
  ## Retrieves metadata for a file or directory at the specified path,
  ## including size, last modified time, and whether it's a directory.
  let full = d.resolvePath(path)
  FileMetadata(
    path: path,
    size: getFileSize(full),
    lastModified: getLastModificationTime(full),
    isDir: dirExists(full)
  )

#
# Filesystem — multi-disk abstraction (like Laravel's Storage facade)
#
type
  Filesystem* = ref object
    ## The Filesystem type provides a multi-disk abstraction where you can define multiple "disks"
    ## (storage backends) and perform file operations on them using a unified interface.
    disks: Table[string, StorageDriver]
    default: string

proc newFilesystem*(defaultDisk = "local"): Filesystem =
  ## Creates a new Filesystem instance with an optional default disk name (default is "local").
  Filesystem(default: defaultDisk)

proc addDisk*(fs: Filesystem, name: string, driver: StorageDriver) =
  ## Adds a new disk (storage backend) to the Filesystem. The `name` is used to reference
  ## this disk in file operations.
  fs.disks[name] = driver

proc disk*(fs: Filesystem, name = ""): StorageDriver =
  ## Retrieves a StorageDriver for the specified disk name. If no name is
  ## provided, it returns the default disk.
  let key = if name.len == 0: fs.default else: name
  if key notin fs.disks:
    raise newException(StorageError, "Disk not found: " & key)
  fs.disks[key]

proc parseYaml*(fs: Filesystem, path: string): YAMLObject =
  ## Convenience method to read and parse a YAML file from the default disk
  let content = fs.disk().read(path)
  parseYaml(content)

proc parseYaml*[T](fs: Filesystem, path: string, t: typedesc[T]): T =
  ## Generic version of parseYaml that returns a typed result. The caller can specify
  ## the expected type (like a config object) and the YAML will be parsed into that type.
  let content = fs.disk().read(path)
  parseYaml(content, t)

proc parseJson*(fs: Filesystem, path: string): JsonNode =
  ## Convenience method to read and parse a JSON file from the default disk
  let content = fs.disk().read(path)
  fromJson(content)

proc parseJson*[T](fs: Filesystem, path: string, t: typedesc[T]): T =
  ## Generic version of parseJson that returns a typed result. The caller can specify
  ## the expected type (like a config object) and the JSON will be parsed into that type.
  let content = fs.disk().read(path)
  fromJson(content, t)

proc parseToml*(fs: Filesystem, path: string): TomlNode =
  ## Convenience method to read and parse a TOML file from the default disk
  let content = fs.disk().read(path)
  parseToml(content)

proc parseCsv*(fs: Filesystem, path: string) =
  ## Convenience method to read and parse a CSV file from the default disk
  discard

proc write*(fs: Filesystem, path, content: string, visibility = visPrivate) {.inline.} =
  ## Convenience method to write a file to the default disk
  fs.disk().write(path, content, visibility)

proc read*(fs: Filesystem, path: string): string  {.inline.} =
  ## Convenience method to read a file from the default disk
  fs.disk().read(path)

proc exists*(fs: Filesystem, path: string): bool {.inline.} =
  ## Convenience method to check if a file exists on the default disk
  fs.disk().exists(path)

proc delete*(fs: Filesystem, path: string) {.inline.} =
  ## Convenience method to delete a file from the default disk
  fs.disk().delete(path)