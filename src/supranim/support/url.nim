#
# Supranim is a full-featured web framework for building
# web apps & microservices in Nim.
# 
#   (c) 2026 LGPL-v3-or-later License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#
import std/[uri, json]
export uri

from ../core/application import appInstance, config

proc link*(path: string): Uri =
  result = initUri()
  result.scheme =
    if appInstance().config("app.ssl").getBool == true:
      "https"
    else:
      "http"
  result.hostname = appInstance().config("app.url").getStr
  result.path =
    if path[0] == '/': path[1..^1]
    else: path

proc link*(path: string, query: openArray[(string, string)]): Uri {.inline.} =
  link(path) ? query
