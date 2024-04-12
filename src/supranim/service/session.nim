# Supranim is a simple MVC web framework
# for building web apps & microservices in Nim.
#
# (c) 2024 MIT License | Made by Humans from OpenPeeps
# https://supranim.com | https://github.com/supranim

import std/options
import pkg/supranim/support/[cookie, nanoid]

import ../service
export options, ZSendRecvOptions

provider Session, RouterDealer:
  # Initializes a new Service Provider based
  # on ZeroMQ's protocol REQUEST/REPLY.
  # which is kinda slow, maybe we should switch
  # to ROUTER/DEALER instead?
  port = 55001
  deps = [SessionManager]
  commands = [
    sessionNew,
    sessionCheck,
    sessionDelete,
    sessionData,
    sessionFlashBag,
    sessionFlashBagGet
  ]

handlers:
  # Here we'll define our backend command handlers
  sessionNew do:
    ## Creates a new `UserSession`
    let uss = newUserSession("", "123")
    let id = uss.client["ssid"].getValue
    Session.sessions[id] = uss
    server.sendAll($uss.client["ssid"])

  sessionCheck do:
    ## Check if there is an active `UserSession`
    if Session.sessions.hasKey(recv[1]):
      let uss = Session.sessions[recv[1]]
      if uss.data != nil:
        if uss.data["loggedin"].getBool == true:
          uss.lastAccess = now()
          server.sendAll($uss.client["ssid"])
        else: server.send("")
      else:
        server.send("")
    else:
      server.send("")

  sessionData do:
    ## Set JSON data for a specific `UserSession`
    let id = recv[1]
    if Session.sessions.hasKey(recv[1]):
      Session.sessions[id].data = jsony.fromJson(recv[2], JsonNode)
      server.send("")
    else:
      server.send("")

  sessionDelete do:
    ## Delete a `UserSession` session
    let id = recv[1]
    if Session.sessions.hasKey(id):
      let clientCookie: ref Cookie = Session.sessions[id].client["ssid"]
      clientCookie.expires()
      server.send($clientCookie)
      Session.sessions.del(id)
      freemem(clientCookie)
    else:
      server.send("")

  sessionFlashBag do:
    ## Set a new flash bag message to `UserSession`
    let id = recv[1]
    if Session.sessions.hasKey(id):
      Session.sessions[id].notifications[recv[3]] = recv[2]
      server.send("")

  sessionFlashBagGet do:
    ## Get a flash bag message from `UserSession`
    let id = recv[1]
    if Session.sessions.hasKey(id):
      if Session.sessions[id].notifications.hasKey(recv[2]):
        server.send(Session.sessions[id].notifications[recv[2]])
        Session.sessions[id].notifications.del(recv[2]) # delete the message
      else: server.send("")
    else: server.send("")

backend:
  # Standalone Session service
  import std/[times, json, strutils, tables]
  import pkg/jsony

  type
    Notification = string
    UserSession {.acyclic.} = ref object
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
    let securedCookie = crypto_box_easy($sessval, Session.nonce, Session.keypair.pk, Session.keypair.sk) 
    let creationTime = now()
    result = UserSession(
      id: id,
      created: creationTime,
      lastAccess: creationTime,
    )
    result.backend["ssid"] = newCookie("ssid", $sessval, creationTime + 60.minutes)
    result.client["ssid"] = newCookie("ssid", result.id, creationTime + 60.minutes)

frontend:
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
    let strCookie = cmd(sessionNew, @[platform, req.getIp])
    if not strCookie.isNone:
      res.addHeader("set-cookie", strCookie.get()[0])
    else:
      raise newException(SessionError, "")

  template initSession*(forceRefresh = false) =
    ## A template for creating new `UserSession` instances.
    ## This template can be used inside a `controller`/`middleware` context
    block:
      let clientCookie: ref Cookie = req.getClientCookie()
      if clientCookie != nil:
        let status = session.cmd(sessionCheck, @[clientCookie.getValue, $clientCookie])
        if status.isNone or forceRefresh:
          session.cmd(sessionDelete, clientCookie.getValue())         
          try:
            initUserSession(req, res)
          except SessionError:
            render("errors.5xx", code = HttpCode(500))
        else: discard # reuse session id 
      else:
        try:
          initUserSession(req, res)
        except SessionError:
          render("errors.5xx", code = HttpCode(500))

  template delete* =
    ## Destroys the current `UserSession`.
    ## Can be used inside a `controller`/`middleware` context
    block:
      let id = req.getClientID
      if likely(id.isSome):
        let someCookie = session.cmd(sessionDelete, id.get())
        if likely(someCookie.isSome):
          res.addHeader("set-cookie", someCookie.get()[0])

  template notify*(msg: string) = 
    ## A template for creating a new
    ## session-based flash bag message.
    block:
      let id = req.getClientID()
      if likely(id.isSome):
        session.cmd(sessionFlashBag, @[id.get(), msg, req.getUriPath()])

  proc getNotify*(req: Request): Option[seq[string]] =
    ## Returns a seq[string] containing flash bag
    ## messages set from the previous request
    let id = req.getClientID()
    if likely(id.isSome):
      result = session.cmd(sessionFlashBagGet, @[id.get(), req.getUriPath()])
