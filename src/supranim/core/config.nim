#
# Supranim is a high-performance web framework for building
# web applications and microservices in Nim
# 
#   (c) 2026 LGPL-v3-or-later License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#

import std/[macros, os]
import pkg/nyml

import ./paths

type
  SupranimEnvLoader* = object of CatchableError

const
  supranimServer* {.strdefine.} = "httpbeast"
    # Choose a preferred web server. Possible values:
    # `httpbeast`, `mummy`, `experimental`

proc loadEnv* =
  ## Loads environment variables from the `.env.yml` file in the project root directory.
  if not fileExists(rootPath / ".env.yml"):
    raise newException(SupranimEnvLoader, "Configuration file '.env.yml' not found in project root directory.")
  let
    envContents = readFile(rootPath / ".env.yml")
    ymlEnv = yaml(envContents).toJson
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
