# Supranim is a simple MVC-style web framework for building
# fast web applications, REST API microservices and other cool things.
#
# (c) 2021 Supranim is released under MIT License
#          Made by Humans from OpenPeep
#          https://supranim.com | https://github.com/supranim

import ./uuid
import std/[cookies, tables, times, options]

from ./str import unquote
from std/strutils import indent, split

export times, uuid

type
    Cookie* = ref object
        # A cookie object structure
        name, value: string
        expires: string
        domain: string
        path: string
        secure: bool
        httpOnly: bool
        maxAge: Option[int]
        sameSite: SameSite
    
    SessionInstance* = object
        id: Uuid
        cookies: Table[string, Cookie]
    
    Sessions = TableRef[string, ref SessionInstance]
    ClientSession = tuple[cookies: string, agent, os: string, mobile: bool]
    SessionManager = object
        sessions: Sessions

when compileOption("threads"):
    # Create a singleton instance of RateLimiter
    # with multi threading support
    var Session* {.threadvar.}: SessionManager
else:
    var Session: SessionManager

#
# Cookie API
#

proc newCookie*(name, value: string, expires: TimeInterval, maxAge = none(int),
                domain = "", path = "", secure = false, httpOnly = true, sameSite = Lax): Cookie =
    let expirationDate = now() + expires
    result = Cookie(
        name: name,
        value: value,
        expires: format(expirationDate.utc, "ddd',' dd MMM yyyy HH:mm:ss 'GMT'"),
        maxAge: maxAge,
        domain: domain,
        path: path,
        secure: secure,
        httpOnly: httpOnly,
        sameSite: sameSite
    )

method has*(session: var SessionInstance, id, key: string) = 
    ## Determine if current Session has a Cookie for given key
    ## This method checks on both client and backend sides.

method getCookies*(session: ref SessionInstance): Table[string, Cookie] =
    ## Get a Cookie instance from current Session based on given Cookie key (name)
    result = session.cookies

method getName(session: ref Cookie, key: string): string =
    ## TODO

method getDomain(session: ref Cookie, key: string): string =
    ## TODO

method isExpired*(session: ref Cookie, key: string): bool =
    ## TODO

method isSecure*(session: ref Cookie, key: string): bool =
    ## TODO

method getSameSite(session: ref Cookie, key: string): string =
    ## TODO

method getPartitionKey(session: ref Cookie, key: string): string =
    ## TODO

proc parseCookies(cookies: string): Table[string, Cookie] =
    for cookie in cookies.split(";"):
        var kv = cookie.split("=")
        result[kv[0]] = newCookie(kv[0], kv[1], 1.hours)

proc kv(k, v: string): string =
    result = k & "=" & v & ";"

proc `$`*(cookie: Cookie): string =
    ## Returns a stringified Cookie
    result.add kv(cookie.name, cookie.value)
    result.add kv("HttpOnly", $cookie.httpOnly)
    result.add kv("Expires", cookie.expires)
    result.add kv("SameSite", $cookie.sameSite)

#
# Session API
#
proc init*(sessions: var SessionManager) =
    ## Initialize a singleton instance of SessionManger
    Session = SessionManager(sessions: newTable[string, ref SessionInstance]())

method flush*(manager: var SessionManager) =
    ## Clear all expired Sessions. This method gets called from `QueueServices`.
    ## For adjusting flushing timing go to your app configuration file.
    ## TODO

proc initClientSession(): ref SessionInstance =
    new(result)
    result.id = uuid4()
    result.cookies["sessid"] = newCookie("sessid", $result.id, 30.minutes)

method newSession*(manager: var SessionManager, client: ClientSession): ref SessionInstance =
    ## Creates a new Session on both sides for client and backend.
    ## If client provides a valid `sessid` cookie, will use that,
    ## otherwise initialize a new client session id.
    if client.cookies.len != 0:
        let clientCookies = parseCookies(client.cookies)
        if clientCookies.hasKey("sessid"):
            if not manager.sessions.hasKey(clientCookies["sessid"].value):
                let sess = initClientSession()
                manager.sessions[$sess.id] = sess
                return manager.sessions[$sess.id]
            return manager.sessions[clientCookies["sessid"].value]
    result = initClientSession()
    manager.sessions[$result.id] = result

method getId*(session: ref SessionInstance): Uuid =
    ## Returns `UUID` of the current `SessionInstance`
    result = session.id
