# Supranim is a simple MVC-style web framework for building
# fast web applications, REST API microservices and other cool things.
#
# (c) 2022 Supranim is released under MIT License
#          Made by Humans from OpenPeep
#          https://supranim.com | https://github.com/supranim

import std/[cookies, tables, options, times]
from std/strutils import indent, split

type
    Cookie* = object
        # A cookie object structure
        name, value: string
        expires: string
        domain: string
        path: string
        secure: bool
        httpOnly: bool
        maxAge: Option[int]
        sameSite: SameSite
    CookiesTable* = TableRef[string, ref Cookie]

proc kv(k, v: string): string = result = k & "=" & v & ";"

proc newCookie*(name, value: string, expires: TimeInterval, maxAge = none(int), domain = "",
                path = "", secure = false, httpOnly = true, sameSite = Lax): ref Cookie =
    ## Create a new `Cookie` object and return as a ref object.
    let expirationDate = now() + expires
    new result
    result.name = name
    result.value = value
    result.expires = format(expirationDate.utc, "ddd',' dd MMM yyyy HH:mm:ss 'GMT'")
    result.maxAge = maxAge
    result.domain = domain
    result.path = path
    result.secure = secure
    result.httpOnly = httpOnly
    result.sameSite = sameSite

method getName*(cookie: ref Cookie): string = result = cookie.name
method getValue*(cookie: ref Cookie): string = result = cookie.value
method getDomain*(cookie: ref Cookie): string = result = cookie.domain
method isExpired*(cookie: ref Cookie): bool =
    result = parse(cookie.expires, "ddd',' dd MMM yyyy HH:mm:ss 'GMT'") > now()

proc parseCookies*(cookies: string): CookiesTable =
    if cookies.len == 0: return
    new result
    for cookie in cookies.split(";"):
        var kv = cookie.split("=")
        result[kv[0]] = newCookie(kv[0], kv[1], 1.hours)

proc `$`*(cookie: ref Cookie): string =
    result.add kv(cookie.name, cookie.value)
    result.add kv("HttpOnly", $cookie.httpOnly)
    result.add kv("Expires", cookie.expires)
    # result.add kv("MaxAge", $(cookie.maxAge.get))
    result.add kv("Domain", $cookie.domain)
    result.add kv("Path", $cookie.path)
    # result.add kv("Secure", $cookie.secure)
    result.add kv("SameSite", $cookie.sameSite)