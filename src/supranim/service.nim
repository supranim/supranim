# Supranim is a simple MVC web framework
# for building web apps & microservices in Nim.
#
# (c) 2024 MIT License | Made by Humans from OpenPeeps
# https://supranim.com | https://github.com/supranim

import pkg/zmq

import std/[os, macros, tables, options,
    sequtils, json, strutils, enumutils]
import pkg/libsodium/[sodium, sodium_sizes]

import ./support/nanoid
import ./core/utils

from std/net import Port, parseIpAddress, `$`

export zmq, options
export sodium, sodium_sizes, enumutils, utils

type
  ServiceProviderErrorMessages* = enum
    staticSettingsUnknownField = "Unrecognized field `$1` for a Service Provider of type `$1`"
  
  ServiceType* = enum
    ## Decide type of the current Service Provider.
    serviceTypeUntyped
      ## This is the default (invalid) Service Type
    RouterDealer
    InProcess
    Singleton
      ## Integrate Supranim/Nimble packages into your application as
      ## a global Singleton. Optionally, enable thread-safe singletons
      ## using `threadsafe = true`
    serviceTypePackage
      ## Integrate any Nimble package into your Supranim application
    serviceTypeLibrary
      ## Integrates Shared Libraries

  ServiceProviderError* = object of CatchableError

var
  serviceCommands {.compileTime.}: Table[string, NimNode]
  serviceHandles {.compileTime.}: Table[string, NimNode]

proc parseFieldsRouterDealer(fields: NimNode): string {.compileTime.} =
  for field in fields:
    let
      fname = field[0]
      fvalue = field[1]
    case field.kind
    of nnkAsgn:
      fname.expectKind nnkIdent
      if fname.eqIdent "port":
        fvalue.expectKind nnkIntLit
        result = $(Port(fvalue.intVal))
      elif fname.eqIdent "deps":
        fvalue.expectKind nnkBracket
        for dep in fvalue:
          dep.expectKind nnkIdent
      elif fname.eqIdent "commands":
        for cmd in fvalue:
          serviceCommands[cmd.strVal] = cmd
      else:
        raise newException(ServiceProviderError, $(staticSettingsUnknownField) % [fname.strVal, ""])
    else: discard

proc parseFieldsInProcess(fields: NimNode) {.compileTime.} =
  for field in fields:
    case field.kind
    of nnkAsgn:
      if field[0].eqIdent "commands":
        field[1].expectKind(nnkBracket)
        for cmd in field[1]:
          serviceCommands[cmd.strVal] = cmd
    else: discard


macro handlers*(x: untyped) =
  ## Define handlers for reach registered command
  x.expectKind nnkStmtList
  result = newStmtList()
  for handle in x:
    expectKind(handle, nnkCall)
    expectKind(handle[1], nnkStmtList)
    let id = handle[0] # command id
    serviceHandles[id.strVal] =
      nnkOfBranch.newTree(id, handle[1])

var serviceEnumName {.compileTime.}: NimNode
var sockaddr {.compileTime.}: string
var appServiceType {.compileTime.}: ServiceType

proc getZSocketType: (NimNode, NimNode) {.compileTime.} =
  case appServiceType
  of RouterDealer:
    result = (ident "DEALER", ident "ROUTER")
  of InProcess:
    result = (ident "PAIR", ident "PAIR")
  else: discard

macro provider*(serviceName: untyped, servicetype: static ServiceType, settings: untyped) =
  ## Create a new Service Provider
  result = newStmtList()
  expectKind serviceName, nnkIdent
  expectKind settings, nnkStmtList
  appServiceType = servicetype
  case servicetype
  of RouterDealer:
    let port = settings.parseFieldsRouterDealer()
    sockaddr = "tcp://127.0.0.1:" & port
  of InProcess:
    settings.parseFieldsInProcess()
    sockaddr = "inproc:/" & getProjectPath() / ".." / ".." / ".cache" / normalize(serviceName.strVal)
    # sockaddr = "inproc:/" & getTempDir() / normalize(serviceName.strVal)
  else: discard
  # Create an enum of commands available on both,
  # back-end and client-side
  var cmdEnumFields =
    newNimNode(nnkEnumTy).add(newEmptyNode())
  serviceEnumName = ident serviceName.strVal & "Commands"
  for k, cmd in serviceCommands: 
    cmdEnumFields.add(cmd)
  add result,
    nnkTypeSection.newTree(
      nnkTypeDef.newTree(
        nnkPostfix.newTree(
          ident "*", serviceEnumName
        ),
        newEmptyNode(),
        cmdEnumFields
      )
    )

macro backend*(x: untyped) = 
  # Back-end API
  # Create the main `case` block statements
  # that routes the command handlers
  var
    mainBodyStmt = newStmtList()
    cmdCaseStmt = newStmtList()
    caseBranches = nnkCaseStmt.newTree()
  add mainbodyStmt, quote do:
    import std/strutils
  add caseBranches, ident("id")
  for k, handle in serviceHandles:
    add caseBranches, handle
  clear(serviceHandles)
  clear(serviceCommands)
  add cmdCaseStmt, caseBranches
  var sockMode = getZSocketType()
  add mainBodyStmt, x

  template zmqServerBody(sockaddr: string, sockMode: (NimNode, NimNode),
      cmdCaseStmt: NimNode, serviceEnum) {.dirty.} =
    var server = listen(sockaddr, sockMode[1])
    while true:
      let sockid = server.receive()
      if len(sockid) > 0:
        let recv = server.receiveAll()
        let id = serviceEnum(parseInt(recv[0]))
        server.send(sockid, SNDMORE)
        cmdCaseStmt
      freemem(sockid)

  case appServiceType
  of RouterDealer:
    add mainBodyStmt,
      newProc(
        ident "initZeroServer",
        body = getAst(
          zmqServerBody(sockaddr, sockMode,
            cmdCaseStmt, serviceEnumName)
        )
      )
    add mainBodyStmt, newCall(ident "initZeroServer")
    # Expose code as a standalone application
    # using `isMainModule` compile-time flag 
    result = newStmtList().add(
      nnkWhenStmt.newTree(
        nnkElifBranch.newTree(
          ident("isMainModule"),
          mainBodyStmt
        )
      )
    )
  of InProcess:
    # Expose code in a separate thread
    # using ZMQ's inproc protocol
    # initServerProc[0] = nnkPostfix.newTree(
    #   ident "*", ident("runProcess")
    # )
    result = newStmtList()
    template initInProcServer(sockaddr: string,
      sockMode: NimNode, cmdCaseStmt: NimNode, serviceEnum) {.dirty.} =
      block:
        var server = listen(sockaddr, sockMode)
        server.setsockopt(zmq.SNDHWM, 200000.cint)
        server.setsockopt(zmq.RCVHWM, 200000.cint)
        proc runProcess*() {.thread.} =
          {.gcsafe.}:
            while true:
              let recv = server.receiveAll()
              if len(recv) > 0:
                let id = serviceEnum(parseInt(recv[0]))
                cmdCaseStmt
        var thr: Thread[void]
        createThread(thr, runProcess)
    getAst(initInProcServer(sockaddr, sockMode[1],
      cmdCaseStmt, serviceEnumName)).copyChildrenTo(mainBodyStmt)
    add result, mainBodyStmt
  else: discard 

macro frontend*(x: untyped) =
  # Front-end API
  var appBodyStmt = newStmtList()
  var sockMode = getZSocketType()[0]
  if sockMode.eqIdent("PAIR"):
    add appBodyStmt, quote do:
      proc cmd*(id: `serviceEnumName`, msg: string): Option[seq[string]] {.discardable.} =
        ## Create a new client and connect with the backend Service via `tcp`
        ## Once done, the client is automatically closed and freed. 
        var client = zmq.connect(`sockaddr`, mode = `sockMode`, server.context)
        client.setsockopt(RCVTIMEO, 10.cint)
        client.sendAll($(symbolRank(id)), msg)
        let recv = client.receiveAll()
        if recv.len == 0:
          client.close()
          freemem(client)
          return
        if recv[0].len != 0:
          client.close()
          freemem(client)
          return some(recv)

      proc cmd*(id: `serviceEnumName`, msgs: seq[string],
          data: JsonNode = nil, flags: ZSendRecvOptions = NOFLAGS): Option[seq[string]] {.discardable.} =
        var client = zmq.connect(`sockaddr`, mode = `sockMode`, server.context)
        # client.setsockopt(zmq.RCVTIMEO, 20.cint)
        # client.setsockopt(zmq.SNDHWM, 200000.cint)
        # client.setsockopt(zmq.RCVHWM, 200000.cint)
        defer:
          client.close()
          freemem(client)
        var x = msgs
        sequtils.insert(x, [$(symbolRank(id))], 0)
        if data != nil:
          x.add($(data))
        client.sendAll(x)
        let recv = client.receiveAll(flags)
        if recv.len == 0:
          return
        if recv[0].len != 0:
          return some(recv)
  else:
    add appBodyStmt, quote do:
      proc cmd*(id: `serviceEnumName`, msg: string): Option[seq[string]] {.discardable.} =
        ## Create a new client and connect with the backend Service via `tcp`
        ## Once done, the client is automatically closed and freed. 
        var client = zmq.connect(`sockaddr`, mode = `sockMode`)
        client.setsockopt(RCVTIMEO, 350.cint)
        defer:
          client.close()
          freemem(client)
        client.sendAll($(symbolRank(id)), msg)
        let recv = client.receiveAll()
        if recv.len == 0: return
        if recv[0].len != 0:
          return some(recv)

      proc cmd*(id: `serviceEnumName`, msgs: seq[string],
          data: JsonNode = nil, flags: ZSendRecvOptions = NOFLAGS): Option[seq[string]] {.discardable.} =
        var client = zmq.connect(`sockaddr`, mode = `sockMode`)
        client.setsockopt(RCVTIMEO, 350.cint)
        var x = msgs
        sequtils.insert(x, [$(symbolRank(id))], 0)
        if data != nil:
          x.add($(data))
        defer:
          client.close()
          freemem(client)
        client.sendAll(x)
        let recv = client.receiveAll(flags)
        if recv.len == 0: return
        if recv[0].len != 0:
          return some(recv)

      proc cmd*(client: ZConnection, id: `serviceEnumName`): seq[string] {.discardable.} =
        ## Use an existing `client` to request a command 
        client.sendAll($(symbolRank(id)))
        result = client.receiveAll()

      proc cmd*(client: ZConnection, id: `serviceEnumName`, msg: string): seq[string] {.discardable.} =
        ## Use an existing `client` to request a command
        ## followed by `msg` data 
        client.sendAll($(symbolRank(id)), msg)
        result = client.receiveAll()

      proc newClient*: ZConnection =
        ## Creates a new `REQ` client connection.
        ## Don't forget to `close` client connection when done
        zmq.connect(`sockaddr`, mode = `sockMode`)
  
  add appBodyStmt, x
  if sockaddr.startsWith("inproc://"):
    result = newStmtList().add(appBodyStmt)
  else:
    result = newStmtList().add(
      nnkWhenStmt.newTree(
        nnkElifBranch.newTree(
          nnkPrefix.newTree(
            ident "not",
            ident "isMainModule",
          ),
          appBodyStmt
        )
      )
    )

  # echo result.repr