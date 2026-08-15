#
# Supranim is a high-performance web framework for building
# web applications and microservices in Nim
# 
#   (c) 2026 LGPL-v3-or-later License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim

## URL helpers for building absolute links from the application configuration.
## The `link` procedures construct a fully-qualified `Uri` from the `app.url`
## and `app.ssl` configuration values (choosing `https` when SSL is enabled),
## optionally appending a query string. `std/uri` is re-exported for
## convenience.

import std/[uri, json]
import pkg/openparser/yaml
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
