#
# Supranim is a high-performance web framework for building
# web applications and microservices in Nim
# 
#   (c) 2026 LGPL-v3-or-later License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#

import std/[strutils, options, json, uri, tables, times]
import std/httpcore except HttpMethod
import std/cookies except `$`

import pkg/openparser/json
import ../support/cookie

from ../network/webserver import Request, send, getIp, getHeaders,
        getMethod, getHeader, findHeader, getQuery, getBody, HttpMethod

export Request, send, getIp, getHeaders, HttpMethod,
      getHeader, findHeader, `$`, getQuery, getBody

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

proc getHost*(req: var Request): string =
  ## Returns the request `Host` header (without port brackets handling
  ## left to `isLoopbackHost`), falling back to the URI hostname.
  let h = req.getHeader("host")
  if h.isSome and h.get().strip().len > 0:
    return h.get().strip()
  result = req.uri.hostname

proc effectiveScheme*(req: var Request, trustProxy = false): string =
  ## Returns the effective request scheme (`http` or `https`).
  ##
  ## The powpow backend serves plain HTTP, so a direct connection is
  ## always `http`. When the app runs behind a reverse proxy (e.g. nginx
  ## with `proxy_set_header X-Forwarded-Proto $scheme;`) and `trustProxy`
  ## is true, the `X-Forwarded-Proto` header (first value wins) or the
  ## RFC 7239 `Forwarded: proto=` parameter decides instead. With
  ## `trustProxy = false` proxy headers are ignored so a spoofed
  ## `X-Forwarded-Proto` cannot flip the `Secure` cookie decision.
  result = effectiveSchemeFromHeaders(
    req.getHeader("x-forwarded-proto").get(""),
    req.getHeader("forwarded").get(""),
    trustProxy
  )

proc isSecureRequest*(req: var Request, trustProxy = false): bool =
  ## Whether the request was made over a secure scheme, honoring
  ## trusted proxy headers when `trustProxy` is true.
  isSecureScheme(req.effectiveScheme(trustProxy))

proc shouldEmitSecure*(req: var Request, mode: CookieSecureMode,
    trustProxy = false): bool =
  ## Whether a `Set-Cookie` response for this request should carry the
  ## `Secure` attribute. `secureAuto` (default) emits it only over
  ## HTTPS, so plain `http://localhost` development cookies (which
  ## Safari drops when marked `Secure`, unlike Chrome/Firefox) keep
  ## working, while proxied HTTPS traffic still gets `Secure`.
  shouldEmitSecureScheme(req.effectiveScheme(trustProxy), mode)

proc newCookieForRequest*(req: var Request, name, value: string,
    mode: CookieSecureMode = secureAuto, trustProxy = false,
    expirationDate: Option[DateTime] = none(DateTime),
    maxAge = none(int), domain = "", path = "/",
    httpOnly = true, sameSite = Strict): Cookie =
  ## Creates a `Cookie` whose `Secure` flag is resolved from the request
  ## via `shouldEmitSecure` instead of being hardcoded.
  newCookie(name, value, expirationDate, maxAge, domain, path,
    secure = req.shouldEmitSecure(mode, trustProxy),
    httpOnly = httpOnly, sameSite = sameSite)

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