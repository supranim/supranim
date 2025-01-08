import std/[macros, os]
import pkg/nyml

import ./paths

const
  supranimServer* {.strdefine.} = "httpbeast"
    # Choose a preferred web server. Possible values:
    # `httpbeast`, `mummy`, `experimental`

macro loadEnvStatic* =
  let
    envContents = staticRead(rootPath / ".env.yml")
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
  result = newStmtList()
  add result, quote do:
    putEnv("database.user", `dbUser`)
    putEnv("database.name", `dbName`)
    putEnv("database.password", `dbPassword`)
    putEnv("database.port", `dbPort`)
  
