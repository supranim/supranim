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

  CookiesTable* = TableRef[string, ref Cookie]

proc kv(k, v: string): string = result = k & "=" & v & ";"

proc newCookie*(name, value: string,
      expirationDate: Option[DateTime] = none(DateTime),
      maxAge = none(int), domain = "", path = "/", secure,
      httpOnly = true, sameSite = Strict): ref Cookie =
  ## Create a new `Cookie` object and return as a ref object.
  new result
  result.name = name
  result.value = value
  result.expires = expirationDate
  result.maxAge = maxAge
  result.domain = domain
  result.path = path
  result.secure = secure
  result.httpOnly = httpOnly
  result.sameSite = sameSite

proc getName*(cookie: ref Cookie): string = cookie.name
proc getValue*(cookie: ref Cookie): string = cookie.value
proc getDomain*(cookie: ref Cookie): string = cookie.domain

proc isExpired*(cookie: ref Cookie): bool =
  if cookie.expires.isSome:
    result = now() >= cookie.expires.get()

proc expires*(cookie: ref Cookie) =
  ## Set `Cookie` as expired
  if cookie.expires.isSome:
    cookie.expires = some(cookie.expires.get() - 1.years)

proc parseCookies*(cookies: string): CookiesTable =
  ## Parse cookies and return a `CookiesTable`
  if cookies.len == 0: return
  new result
  for cookie in cookies.split(";"):
    let kv = cookie.split("=").mapIt(it.strip)
    if kv.len == 2:
      result[kv[0]] = newCookie(kv[0], kv[1], some(now() + 1.hours))

proc `$`*(cookie: ref Cookie): string =
  result.add kv(cookie.name, cookie.value)
  result.add kv("HttpOnly", $cookie.httpOnly)
  if cookie.expires.isSome():
    result.add kv("Expires", format(cookie.expires.get().utc, "ddd',' dd MMM yyyy HH:mm:ss 'GMT'"))
  # result.add kv("MaxAge", $(cookie.maxAge.get))
  result.add kv("Domain", $cookie.domain)
  result.add kv("Path", $cookie.path)
  # when defined release:
  result.add kv("Secure", $cookie.secure)
  result.add kv("SameSite", $cookie.sameSite)
