#
# Supranim is a full-featured web framework for building
# web apps & microservices in Nim.
# 
#   (c) 2025 MIT License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#

import std/[tables, os, strutils]
from std/macros import getProjectPath

const
  supranimBasePath {.strdefine.} =
    when compileOption("app", "lib"):
      getProjectPath().parentDir
    else:
      getProjectPath()
  basePath* = supranimBasePath
  rootPath* = normalizedPath(basepath.parentDir)
  cachePath* = normalizedPath(rootPath / ".cache")
  runtimeConfigPath* = cachePath / "runtime" / "config"
  configPath* = basepath / "config"
  modelPath* = basepath / "model"
  controllerPath* = basepath / "controller"
  servicePath* = basepath / "service"
  middlewarePath* = servicePath / "middleware"
  databasePath* = servicePath / "database"
  eventsPath* = servicePath / "event"
  migrationPath* = databasePath / "migrations"
  storagePath* = basepath / "storage"
  pluginsPath* = storagePath / "plugins"
  logsPath* = storagePath / "logs"
  
  # path to console commands directory
  # where CLI commands are stored as dynamic
  # libraries
  consolePath* = pluginsPath / "console"

type
  ApplicationPaths* = object
    installPath: string
      # absolute path to the installation directory
      
template p*(x: varargs[string]): string =
  path.installPath / x.join("/")

proc init*(path: var ApplicationPaths, installPath: string): bool =
  ## Initialize the application paths
  path.installPath = expandTilde(installPath).expandFilename
  result = dirExists(path.installPath)
  if result:
    discard existsOrCreateDir(p("storage"))
    discard existsOrCreateDir(p("storage", "plugins"))
    discard existsOrCreateDir(p("storage", "templates"))
    discard existsOrCreateDir(p("storage", "logs"))

    discard existsOrCreateDir(p("storage", "public"))

proc getInstallationPath*(path: ApplicationPaths): string =
  ## Returns the installation directory path
  path.installPath  

proc resolve*(path: ApplicationPaths, dir: string, fpath = ""): string =
  ## Returns the absolute path of `dir` directory
  result = path.installPath / dir
  if fpath.len > 0:
    result = result / fpath
