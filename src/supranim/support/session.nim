# Supranim is a simple MVC-style web framework for building
# fast web applications, REST API microservices and other cool things.
#
# (c) 2022 Supranim is released under MIT License
#          Made by Humans from OpenPeep
#          https://supranim.com | https://github.com/supranim

import ./uuid
import std/[cookies, tables, times, options]

from ./str import unquote
from std/strutils import indent, split

export times, uuid

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
    UserSession* = object
        id: Uuid
        backend: CookiesTable
        client: CookiesTable
    
    Sessions = Table[string, UserSession]
    ClientSession* = tuple[cookies: string, agent, os: string, mobile: bool]

    SessionManager = object
        sessions: Sessions

when compileOption("threads"):
    # Create a singleton instance of RateLimiter
    # with multi threading support
    var Session* {.threadvar.}: SessionManager
else:
    var Session*: SessionManager

#
# Cookie API 
#

proc newCookie(name, value: string, expires: TimeInterval, maxAge = none(int), domain = "",
                path = "", secure = false, httpOnly = true, sameSite = Lax): ref Cookie =
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

method getName*(cookie: ref Cookie): string =
    ## Returns the Cookie name
    result = cookie.name

method getValue*(cookie: ref Cookie): string =
    ## Returns the Cookie value
    result = cookie.value

method getDomain*(cookie: ref Cookie): string =
    result = cookie.domain

method isExpired*(cookie: ref Cookie): bool =
    ## Determine if given Cookie is expired
    result = parse(cookie.expires, "ddd',' dd MMM yyyy HH:mm:ss 'GMT'") > now()

method expire*(cookie: ref Cookie) =
    ## TODO

method isSecure*(cookie: ref Cookie): bool =
    ## TODO

method getSameSite*(cookie: ref Cookie): string =
    ## TODO

method getPartitionKey*(cookie: ref Cookie): string =
    ## TODO

proc parseCookies*(cookies: string): CookiesTable =
    if cookies.len == 0: return
    new result
    for cookie in cookies.split(";"):
        var kv = cookie.split("=")
        result[kv[0]] = newCookie(kv[0], kv[1], 1.hours)

proc kv(k, v: string): string =
    result = k & "=" & v & ";"

proc `$`*(cookie: ref Cookie): string =
    result.add kv(cookie.name, cookie.value)
    result.add kv("HttpOnly", $cookie.httpOnly)
    result.add kv("Expires", cookie.expires)
    # result.add kv("MaxAge", $(cookie.maxAge.get))
    result.add kv("Domain", $cookie.domain)
    result.add kv("Path", $cookie.path)
    result.add kv("Secure", $cookie.secure)
    result.add kv("SameSite", $cookie.sameSite)

#
# UserSession API
#
method exists*(session: UserSession, key: string): bool =
    ## Check if there is a Cookie based on given key.
    result = session.backend.hasKey(key) and session.client.hasKey(key)

method getCookies*(session: UserSession): CookiesTable =
    ## Retrieve all Cookies from Backend
    result = session.backend

method getCookie*(session: UserSession, name: string): ref Cookie =
    ## Try get a Cookie by name
    if session.backend.hasKey(name):
        result = session.backend[name]

method getUuid*(session: UserSession): Uuid =
    result = session.id

proc initUserSession(newUuid: Uuid): UserSession =
    result = UserSession(id: newUuid)
    result.backend = newTable[string, ref Cookie]()
    result.backend["ssid"] = newCookie("ssid", $result.id, 30.minutes)

#
# SessionManager API
#
proc init*(sessions: var SessionManager) =
    ## Initialize a singleton instance of SessionManger
    Session = SessionManager()

method isValid*(manager: var SessionManager, id: string): bool =
    result = manager.sessions.hasKey(id)

method newUserSession*(manager: var SessionManager): UserSession =
    var newUuid: Uuid = uuid4()
    while true:
        if manager.sessions.hasKey($newUuid):
           newUuid = uuid4()
        else: break
    result = initUserSession(newUuid)
    manager.sessions[$result.id] = result

method getCurrentSession*(manager: var SessionManager, id: Uuid): UserSession =
    ## Returns the current `UserSession`
    result = manager.sessions[$id]