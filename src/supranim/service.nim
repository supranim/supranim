# Supranim is a simple MVC web framework
# for building web apps & microservices in Nim.
#
# (c) 2024 MIT License | Made by Humans from OpenPeeps
# https://supranim.com | https://github.com/supranim

# Import global modules
import std/[os, strutils, tables, macros,
  macrocache, options, times, sequtils,
  enumutils, json]

import pkg/[zmq, jsony]
import ./core/utils

from supranim/application import cachePath

export zmq, macros, macrocache, enumutils,
  options, json, jsony, freemem

type 
  ServiceProviderErrorMessages* = enum
    spConflictPort = "A service called `$1` already exists for given port `$2`"
    spInvalidConfig = "Invalid configuration for `$1` ServiceProvider"
    spDuplicateCommand = "Duplicate command `$1`"
    staticSettingsUnknownField = "Unrecognized field `$1` for a Service Provider of type `$1`"

  ServiceType* = enum
    RouterDealer = "RouterDealer",
    Inproc = "Inproc"

  ServiceProvider* = ref object of RootObj
    spType*: ServiceType
    spName*, spPort*, spPath*, spDescription*: string
    spAddress*: string
    spCommands*: seq[string]
    spPrivate: bool
    spPrivateKey: string

  ServiceId = string
  ServicePort = string

  ServiceManagerInstance* = ref object
    ports: OrderedTableRef[ServicePort, ServiceId]
    services: OrderedTableRef[ServiceId, ServiceProvider]
    # updateAt: DateTime

var
  ServiceManager {.compileTime.}: ServiceManagerInstance
  identZmqServer {.compileTime.}: NimNode
  service {.compileTime.}: ServiceProvider

const
  ServicesIndex = CacheTable"ServicesIndex"
  cachePathServiceManager = cachePath / "servicemanager.json"
var
  registeredCommands {.compileTime.}: OrderedTable[string, NimNode]
  registeredCommandsParams {.compileTime.}: OrderedTable[string, NimNode]
  baseServiceNode {.compileTime.}: OrderedTable[string, NimNode]
  autorunnable {.compileTime.}: OrderedTable[string, NimNode]

#
# pkg/jsony hooks
#
proc dumpHook*(s: var string, v: DateTime) =
  add s, '"'
  add s, v.format("yyyy-MM-dd'T'HH:mm:ss:zzz")
  add s, '"'

proc parseHook*(s: string, i: var int, v: var DateTime) =
  var str: string
  parseHook(s, i, str)
  v = parse(str, "yyyy-MM-dd'T'HH:mm:ss:zzz")

#
# Service Manager
#
proc checkCommand(x: NimNode) {.compileTime.} =
  if unlikely(registeredCommands.hasKey(x.strVal)):
    error($spDuplicateCommand % x.strVal, x)

proc initServiceManager() {.compileTime.} =
  if fileExists(cachePathServiceManager):
    # initialize ServiceManagerInstance from .cache path
    ServiceManager = jsony.fromJson(
        staticRead(cachePathServiceManager),
        ServiceManagerInstance
      )
  else:
    ServiceManager = new(ServiceManagerInstance)
    new(ServiceManager.ports)
    new(ServiceManager.services)

proc cacheServiceManager {.compileTime.} =
  # ServiceManager.updateAt = now()
  writeFile(cachePathServiceManager, jsony.toJson(ServiceManager))

proc checkPort*(man: ServiceManagerInstance, x: int): bool {.compileTime.} =
  # Check if a ServiceProvider exists at given Port
  man.ports.hasKey($x)

proc getService*(man: ServiceManagerInstance, x: string): ServiceProvider =
  # Get a service by port
  man.services[x]

proc getZSocketType(st: ServiceType): (NimNode, NimNode) {.compileTime.} =
  case st
  of RouterDealer:
    result = (ident "DEALER", ident "ROUTER")
  of Inproc:
    result = (ident "PAIR", ident "PAIR")
  else: discard

proc backendHandleModifier*(handle: NimNode, x: string): NimNode =
  expectKind(handle[4], nnkPragma)
  case handle[4].strVal
  of "command":
    result = handle[2]
  of "commandTask":
    discard

template newService*(serviceId, serviceConfig) =
  ## Generate a new Supranim Service Provider
  macro initService(id, conf): untyped =
    clear(baseServiceNode)
    clear(autorunnable)
    clear(registeredCommandsParams)
    clear(registeredCommands)
    let info: (string, int, int) = instantiationInfo(fullPaths = true)
    id.expectKind(nnkBracketExpr)
    initServiceManager()
    service = ServiceProvider()
    service.spName = id[0].strVal
    service.spType = parseEnum[ServiceType](id[1].strVal)
    service.spPath = info[0]
    for x in conf:
      case x.kind
      of nnkAsgn:
        let k = x[0]
        let v = x[1]
        if k.eqIdent "port":
          if unlikely(ServiceManager.checkPort(v.intVal)):
            # check if a service exists for given port
            let xsrv = ServiceManager.getService(id[0].strVal)
            if unlikely(xsrv.spName != service.spName and xsrv.spPath != service.spPath):
              error($(spConflictPort) % [xsrv.spName, xsrv.spPort], id[0])
          service.spPort = $v.intVal
        elif k.eqIdent "private":
          service.spPrivate = true
          service.spPrivateKey = staticExec("openssl rand -hex 12").strip
        elif k.eqIdent "description":
          service.spDescription = v.strVal
        elif k.eqIdent "commands":
          for cmd in v:
            add service.spCommands, cmd.strVal
      of nnkCommentStmt: discard # ignore comments
      of nnkCall:
        if x[0].eqIdent "before":
          baseServiceNode["before"] = x[1]
      else:
        error($(spInvalidConfig) % [id[0].strVal])
    # reserves given port for the current service
    ServiceManager.ports[service.spPort] = service.spName
    ServiceManager.services[service.spName] = service
    var
      serviceEnumName = ident(id[0].strVal & "Commands")
      serviceEnumFields = nnkEnumTy.newTree(newEmptyNode())
      caseBranches = newNimNode(nnkCaseStmt).add(ident"id")
      bNode = newStmtList()
      bNodeWrappers = newStmtList()
    for x in service.spCommands:
      var xField = ident(x)
      add serviceEnumFields, xField
      # add bNodeWrappers, registeredCommands[x]
      # add caseBranches, nnkOfBranch.newTree(
        # xField,
        # newCall(
        #   registeredCommands[x][0],
        #   ident"server"
        # )
      # )
    # backend node
    baseServiceNode["imports"] = newStmtList()
    add baseServiceNode["imports"],
      nnkImportStmt.newTree(
        nnkInfix.newTree(
          ident"/",
          ident"std",
          nnkBracket.newTree(
            ident"os",
            ident"asyncdispatch",
            ident"strutils",
          )
        )
      )
    add baseServiceNode["imports"],
      nnkImportStmt.newTree(
        nnkInfix.newTree(
          ident"/",
          ident"pkg",
          nnkBracket.newTree(
            ident"jsony",
            nnkInfix.newTree(
              ident"/",
              ident"kapsis",
              ident"cli"
            )
          )
        )
      )
    baseServiceNode["enumCommands"] = newStmtList()
    add baseServiceNode["enumCommands"],
      nnkTypeSection.newTree(
        nnkTypeDef.newTree(
          nnkPostfix.newTree(ident"*", serviceEnumName),
          newEmptyNode(),
          serviceEnumFields
        )
      )
    # add bNode, bNodeWrappers
    if service.spPrivate:
      add bNode, newConstStmt(ident"privateKey", newLit service.spPrivateKey)
    case service.spType:
    of RouterDealer:
      # handle ZMQ Router/Dealer pattern
      #   var server = listen("tcp://127.0.0.1:" & port, mode)
      #   while true:
      #     let sockid = receive(server)
      #     if len(sockid) > 0:
      #       let recv = receiveAll(server)
      #       let id = `serviceEnum`(parseInt(recv[0]))
      #       send(server, sockid, SNDMORE)
      #       caseBranches
      identZmqServer = genSym(nskProc, "initZmqServer")
      service.spAddress = "tcp://127.0.0.1:" & service.spPort
      baseServiceNode[identZmqServer.strVal] =
        newProc(
          identZmqServer,
          body = nnkStmtList.newTree(
            newVarStmt(
              ident"server",
              newCall(
                ident"listen",
                newLit(service.spAddress),
                getZSocketType(service.spType)[1]
              )
            ),
            nnkWhileStmt.newTree(
              ident"true",
              nnkStmtList.newTree(
                newLetStmt(
                  ident"sockid",
                  newCall(ident"receive", ident"server")
                ),
                newIfStmt(
                  (
                    nnkInfix.newTree(
                      ident">",
                      newCall(ident"len", ident"sockid"),
                      newLit(0)
                    ),
                    nnkStmtList.newTree(
                      newLetStmt(ident"recv",
                        newCall(ident"receiveAll", ident"server")
                      ),
                      newLetStmt(
                        ident"id",
                        newCall(
                          serviceEnumName,
                          newCall(
                            ident"parseInt",
                            nnkBracketExpr.newTree(ident"recv", newLit(0))
                          )
                        )
                      ),
                      newCall(ident"send", ident"server", ident"sockid", ident"SNDMORE"),
                      caseBranches
                    )
                  )
                )
              )
            )
          )
        )
    of Inproc:
      # handle ZMQ `inproc` pattern
      identZmqServer = genSym(nskProc, "initZmqServer")
      service.spAddress = "inproc:/" & getProjectPath() / ".." / ".." / ".cache" / normalize(service.spName)
      baseServiceNode[identZmqServer.strVal] = nnkStmtList.newTree(
        newVarStmt(
          ident"server",
          newCall(
            ident"listen",
            newLit(service.spAddress),
            getZSocketType(service.spType)[1]
          )
        ),
        newCall(
          ident"setsockopt",
          ident"server",
          newDotExpr(ident"zmq", ident"SNDHWM"),
          newDotExpr(newLit(200000), ident"cint")
        ),
        newCall(
          ident"setsockopt",
          ident"server",
          newDotExpr(ident"zmq", ident"RCVHWM"),
          newDotExpr(newLit(200000), ident"cint")
        ),
      )
      add baseServiceNode[identZmqServer.strVal],
        newProc(
          identZmqServer,
          pragmas = nnkPragma.newTree(ident"thread"),
          body = nnkStmtList.newTree(
            nnkPragmaBlock.newTree(
              nnkPragma.newTree(ident"gcsafe"),
              nnkWhileStmt.newTree(
                ident"true",
                nnkStmtList.newTree(
                  newLetStmt(ident"recv",
                    newCall(ident"receiveAll", ident"server")
                  ),
                  newIfStmt(
                    (
                      nnkInfix.newTree(
                        ident">",
                        newCall(ident"len", ident"recv"),
                        newLit(0)
                      ),
                      nnkStmtList.newTree(
                        newLetStmt(
                          ident"id",
                          newCall(
                            serviceEnumName,
                            newCall(
                              ident"parseInt",
                              nnkBracketExpr.newTree(ident"recv", newLit(0))
                            )
                          )
                        ),
                        caseBranches
                      )
                    )
                  )
                )
              )
            )
          )
        )
      baseServiceNode["publicInitializer"] = newStmtList()
      add baseServiceNode["publicInitializer"],
        # newProc(
        #   nnkPostfix.newTree(
        #     ident"*",
        #     ident("initProcess"),
        #   ),
          # body = nnkStmtList.newTree(
        nnkVarSection.newTree(
          nnkIdentDefs.newTree(
            ident"ipcthr",
            nnkBracketExpr.newTree(
              ident"Thread",
              ident"void",
            ),
            newEmptyNode()
          )
        )
      add baseServiceNode["publicInitializer"],
        newCall(ident"createThread", ident"ipcthr", identZmqServer)
          # )
        # )
    cacheServiceManager()
  initService(serviceId, serviceConfig)

template checkIsAutorunnable {.dirty.} =
  if isAutoRunnable:
    autorunnable[initialName.strVal] = newNilLit()

template checkEnableAutoRunnable {.dirty.} =
  for prgm in x[4]:
    if prgm.eqIdent("autorunOnce"):
      isAutoRunnable = true

proc safeWrap(x: NimNode, id: string): NimNode =
  # Wraps `x` NimNode inside a `try` `except`
  # block that prevents the app from going down
  # in case something goes wrong.
  result = nnkTryStmt.newTree(
    x,
    nnkExceptBranch.newTree(
      nnkInfix.newTree(
        ident"as",
        ident"CatchableError",
        ident"e",
      ),
      nnkStmtList.newTree(
        newCall(
          ident"displayError",
          newCall(
            ident"format",
            newLit"Command error `$1`: $2",
            newLit id,
            newDotExpr(ident"e", ident"msg")
          )
        )
      )
    )
  )

var defaultZConnection {.compileTime.} = newNilLit()
proc commandCallWithArgs(k: string, defaultZCon = false): NimNode =
  var i = 1
  result = newCall(registeredCommands[k][0])
  for param in registeredCommandsParams[k]:
    if param.kind == nnkIdentDefs:
      if param.len == 3:
        if param[1].eqIdent "JsonNode":
          add result, newCall(            
            newDotExpr(
              ident"jsony",
              ident"fromJson",
            ),
            nnkBracketExpr.newTree(ident"recv", newLit(i))
          )
        else:
          add result, nnkBracketExpr.newTree(
            ident"recv", newLit(i)
          )
        inc i
      else:
        for p in param[0..^3]:
          if param[^2].eqIdent "JsonNode":
            add result, newCall(            
              newDotExpr(
                ident"jsony",
                ident"fromJson",
              ),
              nnkBracketExpr.newTree(ident"recv", newLit(i))
            )
          else:
            add result, nnkBracketExpr.newTree(ident"recv", newLit(i))
          inc i
  if not defaultZCon:
    if service.spType == Inproc:
      add result, newDotExpr(ident"server", ident"context")
    add result, ident("server")

macro command*(x): untyped =
  ## Register a new ZeroMQ command
  let initialName = x[0]
  checkCommand initialName
  var isAutoRunnable: bool
  var cmdProcName = genSym(nskProc, x[0].strVal)
  checkEnableAutoRunnable()
  x[0] = cmdProcName
  registeredCommandsParams[initialName.strVal] = x[3].copy()
  if service.spType == Inproc:
    add x[3], nnkIdentDefs.newTree(ident"context", ident"ZContext", newNilLit())
  add x[3], nnkIdentDefs.newTree(ident"server", ident"ZConnection", defaultZConnection)
  registeredCommands[initialName.strVal] = x

macro asyncTask*(interval: TimeInterval, x: untyped) =
  let initialName = x[0]
  checkCommand initialName
  var
    isAutoRunnable: bool
    cmdProcName = genSym(nskProc, x[0].strVal)
    thProcName = genSym(nskProc, x[0].strVal)
    thrid = genSym(nskVar, x[0].strVal)
    procStmtBody = newStmtList()
  checkEnableAutoRunnable()
  x[4] = newEmptyNode() # reset pragmas
  var innerProcNode = newProc(
    name = thProcName,
    body = nnkStmtList.newTree(
      newLetStmt(
        ident"tasks",
        newCall(ident"newAsyncScheduler")
      ),
      nnkPragmaBlock.newTree(
        nnkPragma.newTree(ident"gcsafe"),
        nnkStmtList.newTree(
          newCall(
            newDotExpr(ident"tasks", ident"every"),
            interval, # get interval node
            newLit(x[0].strVal),
            nnkDo.newTree(
              newEmptyNode(), newEmptyNode(), newEmptyNode(),
              nnkFormalParams.newTree(newEmptyNode()),
              nnkPragma.newTree(ident"async"),
              newEmptyNode(),
              x[6] # get task stmt list
            )
          ),
          newCall(
            ident"waitFor",
            newCall(
              ident "start",
              ident "tasks"
            )
          )
        )
      )
    ),
    pragmas = nnkPragma.newTree(ident"thread")
  )
  add innerProcNode, newCall(ident"start", ident"tasks")
  add procStmtBody, newCommentStmtNode("Auto-generated wrapper around task-based command `" & initialName.strVal & "`")
  add procStmtBody, innerProcNode
  add procStmtBody,
    nnkVarSection.newTree(
      nnkIdentDefs.newTree(
        thrid,
        nnkBracketExpr.newTree(
          ident"Thread",
          ident"void",
        ),
        newEmptyNode()
      )
    )
  add procStmtBody,
    newCall(ident"createThread", thrid, thProcName)
  checkIsAutorunnable()
  if not isAutoRunnable:
    add procStmtBody, newCall(ident"send", ident"server", newLit"")
    defaultZConnection = newEmptyNode()
  registeredCommandsParams[initialName.strVal] = x[3].copy()
  if service.spType == Inproc:
    add x[3], nnkIdentDefs.newTree(ident"context", ident"ZContext", newNilLit())
  add x[3], nnkIdentDefs.newTree(ident"server", ident"ZConnection", defaultZConnection)
  x[6] = procStmtBody
  x[0] = cmdProcName
  registeredCommands[initialName.strVal] = x

template executeServiceCommand*(id: untyped, zaddr: string,
    zmode: ZSocketType, msgs: seq[string] = @[]): untyped =
  # Execute a command of a standalone Service Provider
  var client = zmq.connect(zaddr, mode = zmode)
  client.setsockopt(RCVTIMEO, 200.cint)
  var x = msgs
  sequtils.insert(x, @[$(symbolRank(id))], 0)
  client.sendAll(x)
  let recv = client.receiveAll()
  var resp: Option[seq[string]]
  if recv.len > 0:
    if recv[0].len > 0:
      resp = some(recv)
  client.close()
  freemem(client)
  resp

template executeServiceCommand*(id: untyped, zaddr: string,
    ctx: ZContext, msgs: seq[string] = @[]): untyped =
  # Execute a command of an `inproc` based Service Provider
  var client = zmq.connect(zaddr, mode = PAIR, context = ctx)
  client.setsockopt(RCVTIMEO, 200.cint)
  var x = msgs
  sequtils.insert(x, @[$(symbolRank(id))], 0)
  client.sendAll(x)
  let recv = client.receiveAll()
  var resp: Option[seq[string]]
  if recv.len > 0:
    if recv[0].len > 0:
      resp = some(recv)
  client.close()
  freemem(client)
  resp

macro runService*(frontendBranch): untyped =
  var result,
    mainModule,
    modifiedFrontendBranch = newStmtList()
  let serviceEnumName = service.spName & "Commands"
  add result, baseServiceNode["enumCommands"]
  for enumCommand in service.spCommands:
    # create frontend commands
    var execCallNode: NimNode
    if service.spType == RouterDealer:
      execCallNode =
        newCall(
          ident"executeServiceCommand",
          ident enumCommand,
          newLit("tcp://127.0.0.1:" & service.spPort),
          getZSocketType(service.spType)[0]
        )
    elif service.spType == Inproc:
      execCallNode =
        newCall(
          ident"executeServiceCommand",
          ident enumCommand,
          newLit(service.spAddress),
          newDotExpr(ident"server", ident"context"),
        )
    if registeredCommandsParams.len > 0:
      var asgnArgs = nnkBracket.newTree()
      for param in registeredCommandsParams[enumCommand]:
        if param.kind == nnkIdentDefs:
          if param.len == 3:
            if param[1].eqIdent "JsonNode":
              add asgnArgs, newCall(
                newDotExpr(
                  ident"jsony",
                  ident"toJson",
                ),
                param[0]
              )
            else:
              add asgnArgs, param[0]
          else:
            for p in param[0..^3]:
              add asgnArgs, p
      if asgnArgs.len > 0:
        add execCallNode, nnkPrefix.newTree(ident"@", asgnArgs)
    var frontendProcBody =
      nnkStmtList.newTree(
        newCommentStmtNode("Execute `" & service.spName & "` command `" & enumCommand & "`"),
        execCallNode
      )
    var frontendProc =
      newProc(
        nnkPostfix.newTree(
          ident"*",
          ident("exec" & enumCommand.capitalizeAscii)
        ),
        params = [
          nnkBracketExpr.newTree(
            ident"Option",
            nnkBracketExpr.newTree(
              ident"seq",
              ident"string"
            )
          )
        ],
        pragmas = nnkPragma.newTree(
          ident"discardable"
        ),
        body = frontendProcBody
      )
    if registeredCommandsParams.len > 0:
      for p in registeredCommandsParams[enumCommand][1..^1]:
        add frontendProc[3], p
    add modifiedFrontendBranch, frontendProc

  for k, node in baseServiceNode["imports"]:
    add mainModule, node
  if service.spType != Inproc:
    add mainModule,
      newCall(
        ident"displayInfo",
        newLit("Start `" & service.spName & "` Service Provider")
      )
    add mainModule,
      newCall(
        ident"display",
        newLit("Address: tcp://127.0.0.1:" & service.spPort),
        newLit(6)
      )
  for k, node in baseServiceNode["before"]:
    add mainModule, node
  for k, node in registeredCommands:
    add mainModule, node
    if autorunnable.hasKey(k) and service.spType != Inproc:
      add mainModule,
        newCall(
          ident"displayInfo",
          newLit("Execute auto-runnable command `" & k & "`")
        )
      add mainModule, commandCallWithArgs(k, true)
  if service.spType == Inproc:
    for cmd in service.spCommands:
      add baseServiceNode[identZmqServer.strVal][3][6][0][1][1][1][0][1][1],
        nnkOfBranch.newTree(
          ident cmd,
          safeWrap(commandCallWithArgs(cmd), cmd)
        )
    for x in baseServiceNode[identZmqServer.strVal]:
      add mainModule, x
    add mainModule, baseServiceNode["publicInitializer"]
  else:
    for cmd in service.spCommands:
      add baseServiceNode[identZmqServer.strVal][6][1][1][1][0][1][3],
        nnkOfBranch.newTree(
          ident cmd,
          safeWrap(commandCallWithArgs(cmd), cmd)
        )
    let zmqBaseProc = baseServiceNode[identZmqServer.strVal]
    add mainModule, zmqBaseProc
    add mainModule, newCall(zmqBaseProc[0])
  add modifiedFrontendBranch, frontendBranch
  if service.spType == RouterDealer:
    add result,
      nnkWhenStmt.newTree(
        nnkElifBranch.newTree(
          ident"isMainModule",
          mainModule
        ),
        nnkElse.newTree(
          modifiedFrontendBranch
        )
      )
  else:
    add result, mainModule
    add result, modifiedFrontendBranch
  # debugEcho result.repr
  result

template send*(x: varargs[string]) {.dirty.} =
  server.sendAll(x)
  return # block code execution

template empty* {.dirty.} =
  server.send("")
  return # block code execution

