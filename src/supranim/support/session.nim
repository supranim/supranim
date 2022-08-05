# Supranim is a simple MVC-style web framework for building
# fast web applications, REST API microservices and other cool things.
#
# (c) 2022 Supranim is released under MIT License
#          Made by Humans from OpenPeep
#          https://supranim.com | https://github.com/supranim
import pkginfo
when requires "emitter":
    import emitter
import ./uuid, ./cookie
import std/[tables, times, options]

from ./str import unquote

export times, uuid, cookie

type
    UserSession* = object
        id: Uuid
            ## ID representing the current UserSession
        backend, client: CookiesTable
            ## Table representing all Cookies for both backend and clientside.
            ## Note that `client` table gets parsed data from client side
            ## and gets cleaned after each Response.
        created: DateTime
            ## The creation time for current UserSession
    
    ID* = string
        ## The stringified `UUID`

    Sessions = Table[ID, UserSession]
        ## A table containing all UserSession instances

    SessionManager = ref object
        sessions: Sessions
        expiration: Duration

    SessionDefect* = object of Defect

when compileOption("threads"):
    var Session* {.threadvar.}: SessionManager
else:
    var Session*: SessionManager

#
# UserSession API
#
method exists*(session: UserSession, key: string): bool =
    result = session.backend.hasKey(key) and session.client.hasKey(key)

method getCookies*(session: UserSession): CookiesTable =
    result = session.backend

method newCookie*(session: UserSession, name, value: string): ref Cookie =
    result = newCookie(name, value, 1.hours)
    session.backend[name] = result

method getCookie*(session: UserSession, name: string): ref Cookie =
    if session.backend.hasKey(name):
        result = session.backend[name]

method deleteCookie*(session: UserSession, name: string): bool =
    if session.backend.hasKey(name):
        session.backend.del(name)
        return true

method hasCookie*(session: UserSession, name: string): bool =
    ## Determine if current session has a specific Cookie by name
    result = session.backend.hasKey(name)

method hasExpired*(session: UserSession): bool =
    ## Determine the state of the given session instance.
    ## by checking the creation time and 
    result = now() - session.created >= Session.expiration

method getUuid*(session: UserSession): Uuid =
    ## Retrieves the `UUID` of given the given session instance
    ## Use `$` in order to stringify the ID.
    result = session.id

proc initUserSession(newUuid: Uuid): UserSession =
    result = UserSession(id: newUuid, created: now())
    result.backend = newTable[string, ref Cookie]()
    result.backend["ssid"] = newCookie("ssid", $result.id, 30.minutes)

#
# SessionManager API
# 
proc init*[S: SessionManager](m: var S, expiration = initDuration(minutes = 30)) =
    ## Initialize a singleton of `SessionManager` as `Session`.
    if Session != nil:
        raise newException(SessionDefect, "Session Manager has already been initialized")
    Session = SessionManager(expiration: expiration)

method isValid*(manager: var SessionManager, id: string): bool =
    ## Validates a session by `UUID` and creation time.
    if manager.sessions.hasKey(id):
        result = manager.sessions[id].hasExpired() == false

method flush*(manager: var SessionManager) =
    ## Flush expired `UserSession` instances.
    ##
    ## Do not call this method directly!
    ##
    ## The process of flushing expired sessions is handled
    ## by Scheduler module in a separate thread.
    if manager == nil: return
    var expired: seq[UserSession]
    for id, userSession in manager.sessions.pairs():
        if userSession.hasExpired():
            expired.add userSession
    echo expired.len

method newUserSession*(manager: var SessionManager): UserSession =
    ## Create a new UserSession instance via `SessionManager` singleton
    var newUuid: Uuid = uuid4()
    while true:
        if manager.sessions.hasKey($newUuid):
           newUuid = uuid4()
        else: break
    result = initUserSession(newUuid)
    manager.sessions[$result.id] = result

method getCurrentSessionByUuid*(manager: var SessionManager, id: Uuid): UserSession =
    ## Returns an `UserSession` via `SessionManager` based on given id.
    result = manager.sessions[$id]