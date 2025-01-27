# Supranim - A fast Model-View-Controller web framework in Nim
#
#   (c) 2025 MIT LIcense | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim

import system/ansi_c
import std/[tables, dynlib, times, macros, macrocache,
  posix, exitprocs, options, hashes, httpcore]

import pkg/threading/[rwlock, channels]
import pkg/[taskman, semver]

import supranim/router
import supranim/support/nanoid
import supranim/core/http/autolink

export semver

type
  PluginPermission* = enum
    NoAccess
      ## When the plugin does not specify any requirements
    DBRead
      ## Requires `read` access to the database
    DBWrite
      ## Requires `write` access to the database.
      ## This permission gives the ability to execute `insert`
      ## SQL queries to existing database tables.
    Controller
      ## Requires permission to create new controllers.
    Model
      ## Requires permission to create new Database models.
    Router
      ## Requires permission to add new Routes.
    Middleware
      ## Requires permission to create new Middleware handles
    Afterware
      ## Requires permission to create new Afterware handles
    Filesystem
      ## Requires permission to access the virtual filesystem
    Templates
      ## Requires permission to create new `.timl` templates
    FullAccess
      ## When a plugin requires `FullAccess` it gets access

  PluginStatus* = enum
    StatusUnload, StatusReady, StatusActive, StatusInvalid
  
  RemoteEndpointsResponse = object
    code: HttpCode

  RemoteEndpoints = object
    ## Plugins can use the built-in Updates Checker
    ## and deliver automatic updates via REST API
    endpoint: string
    interval: TimeInterval
    response: RemoteEndpointsResponse

  SystemVersion* = object
    supranimV*, nimV: semver.Version
  
  ModuleType* = enum
    Controller, Model, Middleware, Afterware

  PluginType* = enum
    moduleTypePlugin
    moduleTypePluggableModule

  Plugin* {.inheritable.} = object
    pluginType: PluginType
    id*: string
    status*: PluginStatus
    name*, author*, description*,
      license*, url*: string
    permissions: set[PluginPermission]
    remoteEndpoints*: Option[RemoteEndpoints]
      ## An instance of `RemoteEndpoints`. It checks for
      ## automatic updates at a certain time
    version: semver.Version
    systemVersion: SystemVersion
    scheduler: Scheduler

  PluginsTable = OrderedTableRef[Hash, ptr Plugin]
  PluginsLibsTable = TableRef[Hash, LibHandle]

  PluggableController* {.inheritable.} = object
  PluggableModel* {.inheritable.} = object

  ControllersTable* = OrderedTableRef[Hash, ptr PluggableController]
  ModelsTable = OrderedTableRef[Hash, ptr PluggableModel]
  
  PluginRoutes* = object
    routes*: seq[(string, string, string, HttpMethod)]

  PluginManager* = ref object
    ## Manage plugins and other pluggable modules
    path: string
      ## Path to plugins directory
    plugins: PluginsTable = PluginsTable()
      ## An ordered table of available plugins
    libs: PluginsLibsTable = PluginsLibsTable()
      ## A referenced table holding dynlib.LibHandle
    ids: Table[string, Hash]
      ## A simple table holding nano ids as key
      ## and Hash (plugin path) as value
    controllers: ControllersTable = ControllersTable()
      ## An ordered table holding pluggable Controllers
    models: ModelsTable = ModelsTable()
      ## An ordered table holding pluggable Models
    enableUpdates*: bool

when compileOption("app", "lib"):
  #
  # Plugin API 
  #
  # for building Supranim plugins and other
  # pluggable modules
  #
  import std/[os, strutils, json]
  from std/httpcore import HttpMethod
  export HttpMethod

  const
    defaultInterval = 12.hours
    moduleRoutes = CacheTable"ModuleRoutes"

  proc initRemoteEndpoints*(endpoint: string,
      interval: static TimeInterval = defaultInterval
  ): Option[RemoteEndpoints] =
    ## Initialize a `RemoteEndpoints`
    # when (interval - defaultInterval).hours < 0:
      # static:
        # error("PluginManager - RemoteEndpoints: Provided time interval of " & $interval & " is less than `" & $defaultInterval & "`")
    some RemoteEndpoints(endpoint: endpoint, interval: interval)

  macro exec*(pm: typed, label: static string, body: untyped) =
    # echo pm.getType.treeRepr
    # echo bindSym("PluginManager").getType.treeRepr
    `body`

  macro onLoad*(x: untyped) =
    ## Compile-time macro to run code when the plugin
    ## gets loaded
    discard

  macro onUnload*(x: untyped) =
    ## Compile-time macro to run code when the plugin gets unloaded
    discard

  type RemoteEndpointUri* = tuple[prod, dev: string]
  macro initRemoteChannel*(baseUri: static RemoteEndpointUri, endpoints: untyped) =
    ## Define your remote endpoints to enable the auto-update feature
    when not defined release:
      if not baseUri[0].startsWith"https://":
        error("Building with `-d:release` requires secured HTTPS endpoints")
    for ep in endpoints:
      expectKind(ep, nnkCommand)
      expectKind(ep[0], nnkIdent)   # http method identifier e.g. `GET`
      expectKind(ep[1], nnkStrLit)  # string-based endpoint path
      let httpMethod = parseEnum[HttpMethod](ep[0].strVal.toUpperAscii)
      if ep[2].kind == nnkStmtList:            
        for resStruct in ep[2]:
          echo resStruct.treeRepr
      elif ep[2].kind in {nnkDotExpr, nnkCall}:
        let intInterval = 
          if ep[2].kind == nnkDotExpr: ep[2][0]
          else: ep[2][1]
        echo intInterval.intVal
        echo ep[2].kind
      else:
        error("Expected one of" & $({nnkStmtList, nnkDotExpr, nnkCall}))

  macro plugin*(id, config, init: untyped) =
    ## Create a new Supranim plugin.
    ## 
    ## A plugin is a simple shared library (aka `.so` or `.dylib`)
    ## which can extend the core functionality of your
    ## Supranim web app.
    ## 
    ## Enable Supranim's microservice architecture at compile-time using
    ## the `-d:supraMicroservice` flag. Once enabled you
    ## can build plugins and other pluggable modules
    ## without rebuilding your main web app.
    result = newStmtList()
    expectKind(id, nnkIdent)
    expectKind(config, nnkStmtList)
    var objConstr: NimNode = nnkObjConstr.newTree(id)
    add objConstr,
      nnkExprColonExpr.newTree(ident"name", newLit(id.strVal))
    for f in config:
      if f.kind notin {nnkCall, nnkCommand}:
        error("Invalid field expecting one of " & $({nnkCall, nnkCommand}))
      if f[0].eqIdent"id" or f[0].eqIdent"status" or
        f[0].eqIdent"name" or f[0].eqIdent"scheduler" or
        f[0].eqIdent"remoteEndpoints":
          error("Protected field `" & $f[0] & "` is a read-only property")
      else:
        add objConstr,
          nnkExprColonExpr.newTree(f[0], f[1])
    var loadPluginHandle = newProc(
      nnkPostfix.newTree(ident"*", ident"loadPlugin"),
      params = [nnkPtrTy.newTree(id)],
      body = newStmtList().add(
        newAssignment(
          ident"result",
          nnkCommand.newTree(ident"create", id),
        ),
        newAssignment(
          nnkBracketExpr.newTree(ident"result"),
          objConstr
        )
      )
    )
    # echo loadPluginHandle.repr
    # echo init.treeRepr
    var runPluginHandle = newProc(
      nnkPostfix.newTree(
        ident"*",
        ident"activatePlugin"
      )
    )
    runPluginHandle[3] = init[3]
    runPluginHandle[^1] = init[^1]
    add result,
      nnkTypeSection.newTree(
        nnkTypeDef.newTree(
          nnkPostfix.newTree(ident"*", id),
          newEmptyNode(),
          nnkObjectTy.newTree(
            newEmptyNode(),
            nnkOfInherit.newTree(ident"Plugin"),
            newEmptyNode()
          )
        )
      )
    add result, quote do:
      proc NimMain {.cdecl, importc.}
      {.push exportc, cdecl, dynlib.}
      proc library_init = NimMain()
      `loadPluginHandle`
      `runPluginHandle`
      proc library_deinit = GC_FullCollect()
      {.pop.}

  #
  # Pluggable Modules
  #
  macro `$initRouteMacros`() =
    # Generate route verb macros required for
    # generating routes via pluggable controllers.
    result = newStmtList()
    for verb in httpMethods:
      let httpMethodStr =
        if verb != "ws":
          "Http" & verb
        else: "HttpGet"
      let httpMethodIdent = ident(httpMethodStr)
      let macroIdent = ident(verb)
      add result, quote do:
        macro `macroIdent`*(path: static string, handle: untyped) =
          ## Register a `GET` route with `handle`
          let linked: Autolinked = autolinkController(path.preparePath(), `httpMethodIdent`)
          if not moduleRoutes.hasKey(linked.handleName):
            moduleRoutes[linked.handleName] =
              nnkTupleConstr.newTree(
                newLit(linked[1]),
                newLit(linked[2]),
                ident(`httpMethodStr`),
                handle
              )
          else:
            error("Route conflict: " & `httpMethodStr` & " `" & path & "` (" & linked.handleName & ") already registered", handle)

  `$initRouteMacros`()

  template ctrl*(stmt: typed): untyped =
    ## Create a new pluggable Controller
    module(ModuleType.Controller, stmt)

  template controller*(stmt: typed): untyped =
    ## Create a new pluggable Controller
    module(ModuleType.Controller, stmt)

  macro module*(moduleType: static ModuleType, body: typed): untyped =
    ## Create a pluggable Supranim module.
    result = newStmtList()
    var pluggableControllers = newStmtList()
    var registeredRoutes = nnkPrefix.newTree(
      ident"@",
      newNimNode(nnkBracket)
    )
    for handleKey, routeTuple in moduleRoutes:
      add registeredRoutes[1],
        nnkTupleConstr.newTree(
          newLit(handleKey),
          routeTuple[0],
          routeTuple[1],
          routeTuple[2]
        )
      add pluggableControllers,
        newProc(
          ident(handleKey),
          params = [
            newEmptyNode(),
            nnkIdentDefs.newTree(
              ident"req", 
              nnkPtrTy.newTree(ident"Request"),
              newEmptyNode()
            ),
            nnkIdentDefs.newTree(
              ident"res", 
              nnkPtrTy.newTree(ident"Response"),
              newEmptyNode()
            )
          ],
          body = nnkStmtList.newTree(
            nnkPragmaBlock.newTree(
              nnkPragma.newTree(ident"gcsafe"),
              routeTuple[3]
            )
          )
        )
    add result, quote do:
      proc NimMain {.cdecl, importc.}
      {.push exportc, cdecl, dynlib.}
      proc library_init = NimMain()
      `pluggableControllers`

      proc loadPluginRoutes*: ptr PluginRoutes =
        #
        result = create(PluginRoutes)
        result[].routes = `registeredRoutes`
      
      proc library_deinit = GC_FullCollect()
      {.pop.}

else:
  #
  # PluginManager API
  #
  import std/[os, strutils, sequtils, json]
  import pkg/[jsony, kapsis/cli]

  type
    LoadPluginHandle* = proc: ptr Plugin {.gcsafe, nimcall.}
    LoadPluginRoutes* = proc: ptr PluginRoutes {.gcsafe, nimcall.}
    RunPluginHandle* = proc(pm: ptr PluginManager) {.gcsafe, nimcall.}

    PluginNotification* = enum
      preloadPluginLibraryError
      preloadPluginHandleError
      preloadPluginHandleInstanceError
      preloadPluginSuccess
      pluginActivated
    
    PluginTArg = (ptr PluginManager, string, LibHandle)
    ChannelNotification = (PluginNotification, string)

  var
    prw = createRwLock()
    pthr: Thread[PluginTArg]
    preloadChannel = newChan[ChannelNotification]()
    activateChannel = newChan[ChannelNotification]()

  proc initPluginManager*(enableUpdates = false): PluginManager = 
    new(result)
    result.enableUpdates = enableUpdates

  template cleanupThread = 
    when NimMajor >= 2:
      addExitProc(proc() =
        when compiles(pthread_cancel(pthr.sys)):
          discard pthread_cancel(pthr.sys)
        if not pthr.core.isNil:
          when defined(gcDestructors):
            c_free(pthr.core)
          else:
            deallocShared(pthr.core)
      )

  #
  # Plugins API
  #
  template pluginExists*(key: string, x, y: typed) {.dirty.} =
    let k = hash(key)
    if manager.plugins.hasKey(k):
      x
    else:
      y

  template pluginExistsGet*(key: string, x, y: untyped) {.dirty.} =
    let k = hash(key)
    if manager.plugins.hasKey(k):
      let plib = manager.libs[k]
      var plugin: ptr Plugin = manager.plugins[k]
      x
    else:
      y

  #
  # Plugin Manager - Load pluggable modules
  #
  type
    AutoloadPluggableModule* = object
      controllers*: OrderedTable[string, Callable]
        ## An ordered table containing all pluggable controller handles
      models*: OrderedTable[string, Callable]
        ## Holds all Database Models provided by a pluggable Module
      routes*: ptr PluginRoutes
        ## An ordered table containing routes provided
        ## by the pluggable module

  proc autoloadModule*(manager: PluginManager, path: string, basePath: string): ptr AutoloadPluggableModule =
    ## Autoload pluggable modules available at `/bin/modules`
    if path.endsWith".dylib":
      var lib: LibHandle = dynlib.loadLib(path)
      let fname = path.splitFile.name
      if not lib.isNil:
        displayInfo(
          span("Autoloading Module: " & fname & "\n"),
          cyanSpan(path.replace(basePath), 6)
        )
        # Loading pluggable controller handles and routes
        let loadPluginRoutes = cast[LoadPluginRoutes](lib.symAddr("loadPluginRoutes"))
        result = create(AutoloadPluggableModule)
        if not loadPluginRoutes.isNil:
          let pluginRoutes: ptr PluginRoutes = loadPluginRoutes()
          for r in pluginRoutes[].routes:
            let controllerHandle = cast[Callable](lib.symAddr(r[0]))
            if likely(not controllerHandle.isNil):
              result[].controllers[r[0]] = controllerHandle
            else:
              displayError("Failed to load controller handle `" & r[0] & "`")
          if not pluginRoutes.isNil:
            result[].routes = pluginRoutes
      else:
        displayError("Failed to load: " & fname)

  proc reloadModule*(manager: PluginManager, path: string) =
    ## Reloads a pluggable module by path. Reloading a module
    ## works only if the path has already been loaded.

  #
  # Plugin Manager - Preload
  #
  proc preloadPluginThread(arg: PluginTArg) {.thread.} =
    let plib: LibHandle = dynlib.loadLib(arg[1])
    var msg: ChannelNotification
    if not plib.isNil:
      var preloadHandle = cast[LoadPluginHandle](plib.symAddr("loadPlugin"))
      if preloadHandle.isNil:
        msg[0] = preloadPluginHandleError
      else:
        var plugin: ptr Plugin = preloadHandle()
        if not plugin.isNil:
          let id = nanoid.generate()
          let hashed = arg[1].hash
          writeWith prw:
            plugin[].id = id
            arg[0][].plugins[hashed] = plugin
            arg[0][].libs[hashed] = plib
            arg[0][].ids[id] = hashed
            msg = (preloadPluginSuccess, $plugin[].id)
        else:
          msg[0] = preloadPluginHandleInstanceError
    else:
      msg[0] = preloadPluginLibraryError
    preloadChannel.send(msg)

  proc preload*(manager: PluginManager, path: string): ptr Plugin =
    pluginExists path:
      discard
    do:
      createThread(pthr, preloadPluginThread, (addr(manager), path, nil))
      cleanupThread()
      var msg: ChannelNotification
      while true:
        if preloadChannel.tryRecv(msg):
          var p: ptr Plugin
          readWith prw:
            p = manager.plugins[hash(path)]
            if likely(msg[0] == preloadPluginSuccess):
              p.status = StatusReady
          return p
        sleep(100)

  #
  # Plugin Manager - Unload a plugin
  #
  proc unload*(manager: PluginManager, path: string) =
    pluginExists path:
      let key = hash(path)
      dynlib.unloadLib(manager.libs[key])
      del(manager.libs, key)
      del(manager.plugins, key)
    do: discard

  #
  # Plugin Manager - Auto update checker
  #
  proc runRemoteEndpoints(arg: PluginTArg) {.thread.} =
    # When enabled it will give plugins permission
    # to check for updates via a remote source.
    # 
    # **Note**, this applies to plugins with `StatusReady` or
    # `StatusActive` that implements a valid `RemoteEndpoints`.
    {.gcsafe.}:
      let key = hash(arg[1])
      var p: ptr Plugin = arg[0].plugins[key]
      p.scheduler = newScheduler()
      p.scheduler.every(p.remoteEndpoints.get.interval, p[].name) do ():
        echo "Check for updates: $1 ($2) " %  [p[].name, p[].id]
      p.scheduler.start()

  #
  # Plugin Manager - Activate a plugin
  #
  proc activatePluginThr(arg: PluginTArg) {.thread.} =
    writeWith prw:
      let key = hash(arg[1])
      var
        p: ptr Plugin = arg[0].plugins[key]
        plib: LibHandle = arg[0].libs[key]
        activateHandle = cast[RunPluginHandle](symAddr(plib, "activatePlugin"))
        msg: ChannelNotification
      if not activateHandle.isNil:
        activateHandle(arg[0])
        msg[0] = PluginNotification.pluginActivated
      activateChannel.send(msg)

  proc activate(manager: PluginManager, path: string) =
    pluginExistsGet path:
      createThread(pthr, activatePluginThr, (addr(manager), path, nil))
      cleanupThread()
      var msg: ChannelNotification
      while true:
        if activateChannel.tryRecv(msg):
          var p: ptr Plugin
          readWith prw:
            p = manager.plugins[hash(path)]
            if likely(msg[0] == pluginActivated):
              p.status = StatusActive
          break
        sleep(100)
      echo msg
      if manager.enableUpdates and isSome(plugin.remoteEndpoints):
        var updateCheckThread: Thread[PluginTArg]
        createThread(updateCheckThread,
          runRemoteEndpoints, (addr(manager), path, nil))
    do: discard

  #
  # Plugin Manager - Deactivate a plugin
  #
  proc deactivate(manager: PluginManager, path: string) =
    pluginExistsGet path:
      writeWith prw:
        plugin[].status = StatusReady
    do: discard

  # Runnable example
when isMainModule:
  var pm = initPluginManager(enableUpdates = true)
  for path in ["./libmyplugin.dylib", "./libhello.dylib"]:
    let p: ptr Plugin = pm.preload(path)
    if not p.isNil:
      echo "Preloaded: ", p[].name
      # if p.name == "MyPlugin":
      pm.activate(path)
      pm.deactivate(path)
  while true:
    sleep(100)