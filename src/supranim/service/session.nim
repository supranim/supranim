# Supranim is a simple MVC web framework
# for building web apps & microservices in Nim.
#
# (c) 2024 MIT License | Made by Humans from OpenPeeps
# https://supranim.com | https://github.com/supranim

import std/[options, sequtils]
import pkg/taskman
import pkg/supranim/support/[cookie, nanoid]
import pkg/libsodium/[sodium, sodium_sizes]

import ../service
export options, ZSendRecvOptions

newService Session[RouterDealer]:
  ## Built-in Session service using the Router/Dealer ZMQ's pattern.
  ## Compiles to a standalone binary application for handling
  ## authentication sessions and user-based cookies
  port = 55001
  # deps = [SessionManager]
  description = "Default Supranim Session Manager"
  commands = [
    newSession, checkSession, deleteSession,
    setNotification, getNotification, dataSession
  ]

  before:
    import std/[times, strutils, tables]

    type
      Notification = string
      UserSessionType = enum
        sessionTypeTemporary
        sessionTypePreserve

      UserSession {.acyclic.} = ref object
        `type`: UserSessionType
        id: string
          # A unique NanoID. This may be regenerated
          # without losing other informations
        backend: CookiesTable = CookiesTable()
          # A backend `CookiesTable`
        client: CookiesTable = CookiesTable()
          # Store a copy of the client-side CookiesTable
        notifications: Table[string, Notification]
          # A temporary seq of flash notification messages
          # that will be displayed in the next Response.
        created: DateTime
          # Creation time
        lastAccess: DateTime
        # device: Device
        hasExpired: bool
          # Marks `UserSession` as expired before deleting it.
          # Expired sessions are cleared by the SessionCleaner
          # in a separate process
        data: JsonNode

      Sessions = TableRef[string, UserSession]
      SessionManager = object
        # key: string
        key: string
        keypair: tuple[pk, sk: string] # CryptoBoxPublicKey, CryptoBoxSecretKey
        nonce: string
        sessions: Sessions = Sessions()

    var Session = SessionManager(nonce: randombytes(crypto_box_NONCEBYTES()))
    Session.keypair = crypto_box_keypair()

    proc newUserSession*(platform, ip: string): UserSession =
      ## Creates a new `UserSession` instance.
      var sessval = newJArray()
      sessval.add(newJString ip)
      sessval.add(newJString platform)
      let id = nanoid.generate(size = 42)
      # let securedCookie = crypto_box_easy($sessval, Session.nonce, Session.keypair.pk, Session.keypair.sk) 
      let creationTime = now()
      result = UserSession(
        id: id,
        created: creationTime,
        lastAccess: creationTime,
      )
      result.backend["ssid"] = newCookie("ssid", $sessval, creationTime + 60.minutes)
      result.client["ssid"] = newCookie("ssid", result.id, creationTime + 60.minutes)

let defaultDuration = initDuration(minutes=60)
proc cleanup() {.asyncTask: 10.minutes, autorunOnce.} =
  ## An async task-based command that clears old session instances
  ## This command is for internal-use only
  let nowTime = now()
  var i = 0
  let keys = Session.sessions.keys.toSeq
  while i <= keys.high:
    let uss = Session.sessions[keys[i]]
    if (nowTime - uss.created >= defaultDuration) and (nowTime - uss.lastAccess >= defaultDuration):
      displayInfo("Delete expired session " & uss.id)
      Session.sessions.del(uss.id)
      freemem(uss)
    inc i

proc newSession(clientBrowser, clientIp: string) {.command.} = 
  ## Create a new `UserSession`
  let uss = newUserSession(clientBrowser, clientIp)
  let id = uss.client["ssid"].getValue
  Session.sessions[id] = uss
  send($uss.client["ssid"])

proc checkSession(clientId, clientIp, clientPlatform: string) {.command.} =
  ## Check if Session contains an active
  ## `ssid` based on `clientId`
  if Session.sessions.hasKey(clientId):
    let uss = Session.sessions[clientId]
    if likely(uss.data != nil):
      if uss.data != nil:
        if uss.data["ip"].getStr == clientIp and
           uss.data["platform"].getStr == clientPlatform:
          uss.lastAccess = now()
          send($uss.client["ssid"])
        else: discard
  empty()

proc deleteSession(clientId: string) {.command.} =
  if likely(Session.sessions.hasKey(clientId)):
    var clientCookie: ref Cookie = Session.sessions[clientId].client["ssid"]
    clientCookie.expires()
    server.send($clientCookie)
    Session.sessions.del(clientId)
    freemem(clientCookie)
  else:
    empty()

proc setNotification(clientId, key, msg: string) {.command.} =
  ## Store a new flash bag notification message
  if likely(Session.sessions.hasKey(clientId)):
    Session.sessions[clientId].notifications[key] = msg
  empty()

proc getNotification(clientId, key: string) {.command.} =
  ## Retrieve a flash bag notification message
  if Session.sessions.hasKey(clientId):
    if Session.sessions[clientId].notifications.hasKey(key):
      server.send(Session.sessions[clientId].notifications[key])
      Session.sessions[clientId].notifications.del(key) # delete the message
      return
  empty()

proc dataSession(clientId: string, data: JsonNode) {.command.} =
    ## Set JSON data for a specific `UserSession`
    if Session.sessions.hasKey(clientId):
      Session.sessions[clientId].data = data
    empty()

runService do:
  # Service Provider API for the main application
  import std/json
  from std/strutils import unescape
  from ../core/request import Request, getPlatform, getIp
  from ../core/response import Response, addHeader
  from ../controller import getClientId, getClientCookie, getUriPath
  
  export cookie, json

  type
    SessionError* = object of CatchableError

  proc initUserSession*(req: Request, res: var Response) = 
    ## Initializes a new `UserSession` then inject a
    ## `set-cookie` header for the upcoming `res` Response. 
    let platform =
      if req.getPlatform.len > 0:
        unescape(req.getPlatform)
      else: ""
    let strCookie = execNewSession(platform, req.getIp)
    if strCookie.isSome:
      res.addHeader("set-cookie", strCookie.get()[0])
    else:
      raise newException(SessionError, "Could not create a new Session")

  template initSession*(forceRefresh = false) =
    ## A template for creating new `UserSession` instances.
    ## This template can be used inside a `controller`/`middleware` context
    block:
      let clientCookie: ref Cookie = req.getClientCookie()
      if clientCookie != nil:
        let status = execCheckSession(clientCookie.getValue, req.getIp, req.getPlatform)
        if forceRefresh:
          execDeleteSession(clientCookie.getValue())
          try:
            initUserSession(req, res)
          except SessionError as e:
            render("errors.5xx", code = HttpCode(500))
        elif status.isNone:
          initUserSession(req, res)
        else: discard # reuse session id 
      else:
        try:
          initUserSession(req, res)
        except SessionError as e:
          render("errors.5xx", code = HttpCode(500))

  template delete* =
    ## Destroys the current `UserSession`.
    ## Can be used inside a `controller`/`middleware` context
    block:
      let id = req.getClientID
      if likely(id.isSome):
        let someCookie = execDeleteSession(id.get())
        if likely(someCookie.isSome):
          res.addHeader("set-cookie", someCookie.get()[0])

  template notify*(msg: string) = 
    ## A template for creating a new
    ## session-based flash bag message.
    block:
      let id = req.getClientID()
      if likely(id.isSome):
        execSetNotification(id.get, req.getUriPath, msg)

  proc getNotify*(req: Request): Option[seq[string]] =
    ## Returns a seq[string] containing flash bag
    ## messages set from the previous request
    let id = req.getClientID()
    if likely(id.isSome):
      result = execGetNotification(id.get(), req.getUriPath())
