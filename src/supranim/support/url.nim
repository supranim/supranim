# Supranim is a lightweight, high-performance MVC framework for Nim,
# designed to simplify the development of web applications and REST APIs.
#
# It features intuitive routing, modular architecture, and built-in support
# for modern web standards, making it easy to build scalable and maintainable
# projects.
#
# (c) 2025 Supranim | MIT License
#     Made by Humans from OpenPeeps
#     https://supranim.com | https://github.com/supranim

import std/[uri, json]
export uri

from pkg/supranim/application import appInstance, config

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
