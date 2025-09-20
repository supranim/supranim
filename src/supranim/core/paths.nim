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
  controllerPath* = basepath / "controller"
  middlewarePath* = basepath / "middleware"
  databasePath* = basepath / "database"
  servicePath* = basepath / "service"
  modelPath* = databasePath / "models"
  migrationPath* = databasePath / "migrations"
  storagePath* = basepath / "storage"
  pluginsPath* = storagePath / "plugins"
  logsPath* = storagePath / "logs"

  # binPaths
  # binPath* = normalizedPath(rootPath / "bin")
  # binModulesPath = binPath / "modules"
  # binController* = binModulesPath / "controller"
  # binModel* = binModulesPath / "model"
  # binServices* = binPath / "service"
  # binStorage* = binPath / "storage"
  # binStorageUploads* = binStorage / "uploads"
  # binTemplates* = binPath / "templates"

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