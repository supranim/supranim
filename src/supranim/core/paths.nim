from std/macros import getProjectPath
from std/os import normalizedPath, parentDir, `/`, `/../`

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
  binPath* = normalizedPath(rootPath / "bin")
  binModulesPath = binPath / "modules"
  binController* = binModulesPath / "controller"
  binModel* = binModulesPath / "model"
  binServices* = binPath / "service"