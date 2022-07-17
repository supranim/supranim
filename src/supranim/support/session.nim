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
    SessionInstance* = object
        id: Uuid
        backend: CookiesTable
        client: CookiesTable
    
    Sessions = TableRef[string, SessionInstance]
    ClientSession* = tuple[cookies: string, agent, os: string, mobile: bool]

    SessionManager = object
        sessions: Sessions

when compileOption("threads"):
    # Create a singleton instance of RateLimiter
    # with multi threading support
    var Session* {.threadvar.}: SessionManager
else:
    var Session: SessionManager

#
# SessionInstance API
#
method exists*(session: SessionInstance, key: string): bool =
    ## Check if there is a Cookie based on given key.
    result = session.backend.hasKey(key) and session.client.hasKey(key)

method getCookies*(session: SessionInstance): CookiesTable =
    ## Retrieve all Cookies from Backend
    result = session.backend

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
    result = cookie.name

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

proc parseCookies(cookies: string): CookiesTable =
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
    result.add kv("MaxAge", $cookie.maxAge)
    result.add kv("Domain", $cookie.domain)
    result.add kv("Path", $cookie.path)
    result.add kv("Secure", $cookie.secure)
    result.add kv("SameSite", $cookie.sameSite)

#
# Session API
#
proc init*(sessions: var SessionManager) =
    ## Initialize a singleton instance of SessionManger
    Session = SessionManager(sessions: newTable[string, SessionInstance]())

method flush*(manager: var SessionManager) =
    ## Clear all expired Sessions. This method gets called from `QueueServices`.
    ## For adjusting flushing timing go to your app configuration file.
    ## TODO

proc initClientSession(): SessionInstance =
    result = SessionInstance(id: uuid4())
    result.backend = newTable[string, ref Cookie]()
    result.backend["sessid"] = newCookie("sessid", $result.id, 30.minutes)

method newSession*(manager: var SessionManager, client: ClientSession): SessionInstance =
    ## Creates a new Session on both sides for client and backend.
    ## If client provides a valid `sessid` cookie, will use that,
    ## otherwise initialize a new client session id.
    if client.cookies.len == 0:
        result = initClientSession()
        manager.sessions[$result.id] = result
        return manager.sessions[$result.id]
    let clientCookies = parseCookies(client.cookies)
    if clientCookies.hasKey("sessid"):
        if not manager.sessions.hasKey(clientCookies["sessid"].value):
            let sess = initClientSession()
            manager.sessions[$sess.id] = sess
            return manager.sessions[$sess.id]
        result = manager.sessions[clientCookies["sessid"].value]

method getId*(session: SessionInstance): Uuid =
    ## Returns `UUID` of the current `SessionInstance`
    result = session.id
