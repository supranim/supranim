#
# Supranim is a high-performance web framework for building
# web applications and microservices in Nim
# 
#   (c) 2026 LGPL-v3-or-later License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#
import std/[cookies, tables, options,
            strutils, times, sequtils]

## This module implements a simple cookie handling system for Supranim, allowing you to create,
## parse, and manage HTTP cookies in your web applications. It provides a `Cookie` object
## with properties like name, value, domain, path, expiration, and security flags. You
## can use the `newCookie` procedure to create cookies and the `parseCookies` procedure to parse
## cookies from request headers. The module also includes utility functions for checking cookie
## expiration and formatting cookies for HTTP responses.

type
  Cookie* = object
    name, value, domain, path: string
    expires: Option[DateTime]
    secure, httpOnly: bool
    maxAge: Option[int]
    sameSite: SameSite

  CookiesTable* = TableRef[string, Cookie]

  CookieSecureMode* = enum
    ## Policy for emitting the `Secure` cookie attribute.
    secureAuto = "auto"
      ## Emit `Secure` only when the effective request scheme is secure
      ## (`https`). Plain `http://localhost` omits it, which Safari
      ## requires (unlike Chrome/Firefox it does not treat `localhost`
      ## as a secure context and drops `Secure` cookies over plain HTTP).
    secureAlways = "always"
      ## Always emit `Secure`, even over plain HTTP (browsers will drop it).
    secureNever = "never"
      ## Never emit `Secure`, even over HTTPS.

proc parseSecureMode*(s: string): CookieSecureMode =
  ## Parses `auto | always | never` (case-insensitive) into `CookieSecureMode`.
  ## Unknown values fall back to `secureAuto`.
  case s.strip().toLowerAscii()
  of "always": secureAlways
  of "never": secureNever
  else: secureAuto

proc isLoopbackHost*(host: string): bool =
  ## Whether `host` is a loopback/local-development host.
  var h = host.strip().toLowerAscii()
  if h.len == 0: return true
  # strip port and brackets (`[::1]:8080` -> `::1`)
  if h.startsWith("["):
    let closeIdx = h.find(']')
    if closeIdx > 0:
      h = h[1 ..< closeIdx]
  elif h.count(':') == 1:
    h = h.split(':')[0]
  if h == "localhost" or h.endsWith(".localhost") or h == "::1":
    return true
  if h.startsWith("127."):
    let parts = h.split('.')
    if parts.len == 4:
      var allNumeric = true
      for p in parts:
        if p.len == 0 or not p.allCharsInSet({'0'..'9'}):
          allNumeric = false
          break
      if allNumeric: return true
  false

proc firstForwardedProto*(value: string): string =
  ## Returns the first protocol token of an `X-Forwarded-Proto`
  ## header value (`https, http` -> `https`), lowercased.
  let v = value.strip()
  if v.len == 0: return ""
  result = v.split(',')[0].strip().toLowerAscii()

proc forwardedHeaderProto*(value: string): string =
  ## Extracts `proto=<scheme>` from an RFC 7239 `Forwarded` header.
  ## Returns `""` when absent.
  for part in value.split(','):
    for pair in part.split(';'):
      let kv = pair.strip().split('=', maxsplit = 1)
      if kv.len == 2 and kv[0].strip().toLowerAscii() == "proto":
        return kv[1].strip().strip(chars = {'"', '\''}).toLowerAscii()
  ""

proc isSecureScheme*(scheme: string): bool =
  ## Whether `scheme` counts as secure (`https`/`wss`, case-insensitive).
  let s = scheme.strip().toLowerAscii()
  s == "https" or s == "wss"

proc effectiveSchemeFromHeaders*(xForwardedProto, forwardedHeader: string,
    trustProxy: bool, defaultScheme = "http"): string =
  ## Resolves the effective request scheme without touching `Request`
  ## (pure and unit-testable). When `trustProxy` is false the proxy
  ## headers are ignored so a spoofed `X-Forwarded-Proto` cannot
  ## upgrade/downgrade the `Secure` decision.
  if trustProxy:
    let p = firstForwardedProto(xForwardedProto)
    if p.len > 0: return p
    let f = forwardedHeaderProto(forwardedHeader)
    if f.len > 0: return f
  defaultScheme

proc shouldEmitSecureScheme*(scheme: string,
    mode: CookieSecureMode): bool =
  ## Pure `Secure` decision from an already-resolved scheme.
  case mode
  of secureAlways: true
  of secureNever: false
  of secureAuto: isSecureScheme(scheme)

proc kv(k, v: string): string = result = k & "=" & v & ";"

proc newCookie*(name, value: string,
      expirationDate: Option[DateTime] = none(DateTime),
      maxAge = none(int), domain = "", path = "/", secure = false,
      httpOnly = true, sameSite = Strict): Cookie =
  ## Create a new `Cookie` object.
  Cookie(
    name: name,
    value: value,
    expires: expirationDate,
    maxAge: maxAge,
    domain: domain,
    path: path,
    secure: secure,
    httpOnly: httpOnly,
    sameSite: sameSite
  )

proc getName*(cookie: Cookie): string = cookie.name
proc getValue*(cookie: Cookie): string = cookie.value
proc getDomain*(cookie: Cookie): string = cookie.domain

proc isExpired*(cookie: Cookie): bool =
  if cookie.expires.isSome:
    result = now() >= cookie.expires.get()

proc expires*(cookie: var Cookie) =
  ## Set `Cookie` as expired by pushing expiration to the past.
  ## Works for both session cookies (no expiry) and persistent cookies.
  cookie.expires = some(now() - 1.years)

proc parseCookies*(cookies: string): CookiesTable =
  ## Parse cookies and return a `CookiesTable`
  if cookies.len == 0: return
  new result
  for cookie in cookies.split(";"):
    let kv = cookie.split("=").mapIt(it.strip)
    if kv.len == 2:
      result[kv[0]] = newCookie(kv[0], kv[1], some(now() + 1.hours))

proc `$`*(cookie: Cookie): string =
  result.add kv(cookie.name, cookie.value)
  if cookie.httpOnly:
    result.add "HttpOnly;"
  if cookie.expires.isSome():
    result.add kv("Expires", format(cookie.expires.get().utc, "ddd',' dd MMM yyyy HH:mm:ss 'GMT'"))
  if cookie.maxAge.isSome:
    result.add kv("Max-Age", $cookie.maxAge.get)
  if cookie.domain.len > 0:
    result.add kv("Domain", cookie.domain)
  result.add kv("Path", cookie.path)
  if cookie.secure:
    result.add "Secure;"
  result.add kv("SameSite", $cookie.sameSite)
