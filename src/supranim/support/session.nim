# Supranim is a simple MVC-style web framework for building
# fast web applications, REST API microservices and other cool things.
#
# (c) 2022 Supranim is released under MIT License
#          Made by Humans from OpenPeep
#          https://supranim.com | https://github.com/supranim
import pkg/[pkginfo, nimcrypto]
when requires "emitter":
  import emitter

import ./uuid, ./cookie
import std/[tables, times, options, httpcore]

from ./str import unquote
from ../core/private/server import Request, getHeaders, getHeader, getIp

export times, uuid, cookie

type
  UserSession* = object
    id: Uuid
      ## ID representing the current UserSession
    id256: string
    reqHeaders: Option[HttpHeaders]
    backend, client: CookiesTable
      ## Table representing all Cookies for both backend and clientside.
      ## Note that `client` table gets parsed data from client side
      ## and gets cleaned after each Response.
    created: DateTime
      ## The creation time for current UserSession
    lastAccess: DateTime
      ## Store last time access in order to extend
      ## the expiration time.

  ID* = string
    ## The stringified `UUID`

  Sessions = TableRef[ID, UserSession]
    ## A table containing all UserSession instances

  SessionManager = ref object
    sessions: Sessions
    expiration: Duration

  SessionDefect* = object of Defect

# when compileOption("threads"):
#   var Session* {.threadvar.}: SessionManager
# else:
var Session*: SessionManager

#
# UserSession API
#
proc exists*(session: UserSession, key: string): bool =
  result = session.backend.hasKey(key) and session.client.hasKey(key)

proc getCookies*(session: UserSession): CookiesTable =
  result = session.backend

proc newCookie*(session: UserSession, name, value: string): ref Cookie =
  result = newCookie(name, value, 1.hours)
  session.backend[name] = result

proc getCookie*(session: UserSession, name: string): ref Cookie =
  if session.backend.hasKey(name):
    result = session.backend[name]

proc deleteCookie*(session: UserSession, name: string): bool =
  if session.backend.hasKey(name):
    session.backend.del(name)
    return true

proc hasCookie*(session: UserSession, name: string): bool =
  ## Determine if current session has a specific Cookie by name
  result = session.backend.hasKey(name)

proc hasExpired*(session: UserSession): bool =
  ## Determine the state of the given session instance.
  ## by checking the creation time and 
  result = now() - session.created >= Session.expiration

proc getUuid*(session: UserSession): Uuid =
  ## Retrieves the `UUID` of given the given session instance
  ## Use `$` in order to stringify the ID.
  result = session.id

proc getHashed(id: Uuid): string =
  result = $keccak_256.digest($id)

proc getHashed(key: string): string =
  result = $keccak_256.digest(key)

proc initUserSession(newUuid: Uuid, req: Request): UserSession =
  result = UserSession(
    id: newUuid,
    id256: getHashed newUuid,
    reqHeaders: req.getHeaders(),
    created: now()
  )
  result.backend = newTable[string, ref Cookie]()
  result.backend["ssid"] = newCookie("ssid", getHashed result.id, 30.minutes)

#
# SessionManager API
# 
proc init*(m: var SessionManager, expiration = initDuration(minutes = 30)) =
  ## Initialize a singleton of `SessionManager` as `Session`.
  if Session != nil:
    raise newException(SessionDefect, "Session Manager has already been initialized")
  Session = SessionManager(expiration: expiration, sessions: newTable[ID, UserSession]())

proc isValid*(manager: var SessionManager, id: string): bool =
  ## Validates a session by `UUID` and creation time.
  if manager.sessions.hasKey(id):
    result = manager.sessions[id].hasExpired() == false

proc flush*(manager: var SessionManager) =
  ## Flush expired `UserSession` instances.
  ##
  ## Do not call this proc directly!
  ##
  ## Flushing expired sessions is handled
  ## by Scheduler module from a separate thread.
  if manager == nil: return
  var expired: seq[UserSession]
  for id, userSession in manager.sessions.pairs():
    if userSession.hasExpired():
      expired.add userSession

proc newUserSession*(manager: var SessionManager, req: Request): UserSession =
  ## Create a new UserSession instance via `SessionManager` singleton
  var newUuid: Uuid = uuid4()
  while true:
    if manager.sessions.hasKey($newUuid):
       newUuid = uuid4()
    else: break
  # echo req.getHeaders().get()
  # echo req.getHeader("user-agent")
  # echo req.getHeader("sec-ch-ua-platform")
  # echo req.getHeader("sec-ch-ua")
  # echo req.getHeader("cookie")
  # echo req.getIp()
  result = initUserSession(newUuid, req)
  manager.sessions[$result.id] = result

proc getCurrentSessionByUuid*(manager: var SessionManager, id: Uuid): UserSession =
  ## Returns an `UserSession` via `SessionManager` based on given id.
  result = manager.sessions[$id]