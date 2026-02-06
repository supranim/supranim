#
# Supranim - A high-performance MVC web framework for Nim,
# designed to simplify web application and REST API development.
# 
#   (c) 2025 MIT License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#

import std/[strutils, options, json, httpcore, uri, tables]
import pkg/jsony

import ../support/cookie

from ../network/http/webserver import Request, send, getIp, getHeaders,
        getMethod, getHeader, findHeader, getQuery, getBody

export Request, send, getIp, getHeaders,
      getHeader, findHeader, `$`, getQuery, getBody

export httpcore

proc getHttpMethod*(req: var Request): HttpMethod =
  ## Returns the `HttpMethod` from `Request`
  result = req.getMethod()

proc getUrl*(req: Request): string =
  ## Returns a string `Uri` from `Request`
  result = $(req.uri)

proc getUriPath*(req: Request): string =
  ## Returns `Uri` path from `Request`
  result = req.uri.path

proc hasCookies*(req: var Request): bool =
  ## Check if `Request` contains Cookies header
  result = req.getHeaders().get.hasKey("cookie")

proc getCookies*(req: var Request): Option[string] =
  ## Returns Cookies header from `Request`
  result = req.getHeader("cookie")

proc getAgent*(req: var Request): Option[string] =
  ## Retrieves the user agent from request header
  result = req.getHeader("user-agent")

proc getBrowserName*(req: var Request): Option[string] =
  ## Retrieves the browser name from `sec-ch-ua` header
  ## https://wicg.github.io/ua-client-hints/#sec-ch-ua
  result = req.getHeader("sec-ch-ua")

proc getPlatform*(req: var Request): Option[string] =
  ## Return the platform name, It can be one of the following
  ## common platform values: `Android`, `Chrome OS`, `iOS`,
  ## `Linux`, `macOS`, `Windows`, or `Unknown`.
  ## https://wicg.github.io/ua-client-hints/#sec-ch-ua-platform
  result = req.getHeader("sec-ch-ua-platform")
  if result.isNone():
    # fallback to the `user-agent` header to get the OS platform
    let agent = req.getAgent().get("")
    if agent.contains("Windows"):
      result = some("Windows")
    elif agent.contains("Macintosh") or agent.contains("Mac OS X"):
      result = some("macOS")
    elif agent.contains("Linux"):
      result = some("Linux")
    elif agent.contains("Android"):
      result = some("Android")
    elif agent.contains("iOS") or agent.contains("iPhone") or agent.contains("iPad"):
      result = some("iOS")
    else:
      result = some("Unknown")

proc getClientData*(req: var Request): JsonNode =
  ## Returns the client data from the request
  %*{
    "ip": req.getIp(),
    "platform": req.getPlatform().get(),
    "agent": req.getAgent().get("unknown"),
    "sec-ch-ua": req.getBrowserName().get("unknown")
  }