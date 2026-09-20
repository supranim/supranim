#
# Supranim is a high-performance web framework for building
# web applications and microservices in Nim
# 
#   (c) 2026 LGPL-v3-or-later License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim

## URL helpers for building absolute links from the application configuration.
## The `link` procedures construct a fully-qualified `Path` from the `app.url`
## and `app.ssl` configuration values (choosing `https` when SSL is enabled),
## optionally appending a query string. `openparser/path` is re-exported for
## convenience.

import pkg/openparser/path
export path

from ../core/application import appInstance, config, getStr, getBool

proc link*(pathStr: string): Path =
  ## Builds an absolute web `Path` for `pathStr` using the `app.url`
  ## hostname and the `app.ssl` flag for the scheme (`https` when enabled,
  ## otherwise `http`).
  ##
  ## `pathStr` may be given with or without a leading `/`; an empty
  ## string resolves to `/`. A port embedded in `app.url`
  ## (e.g. `localhost:8080`) is preserved via `parsePath`.
  let scheme =
    if appInstance().config("app.ssl").getBool():
      "https"
    else:
      "http"
  let host = appInstance().config("app.url").getStr()
  var p = pathStr
  if p.len == 0:
    p = "/"
  elif p[0] != '/':
    p = "/" & p
  result = parsePath(scheme & "://" & host & p)

proc link*(pathStr: string, query: openArray[(string, string)]): Path =
  ## Builds an absolute web `Path` like `link(string)`, additionally
  ## attaching each `query` pair as the URL query string.
  result = link(pathStr)
  for pair in query:
    result.query.add((key: pair[0], value: pair[1]))
  result.raw = $result
