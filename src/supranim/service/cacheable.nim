#
# Supranim is a high-performance web framework for building
# web applications and microservices in Nim
# 
#   (c) 2026 LGPL-v3-or-later License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#

## This service provider implements a simple in-memory cache system with support for
## multiple named storages (buckets) and basic CRUD operations on cache entries.
## It serves as an example of how to create a custom Service Provider in Supranim,
## demonstrating the use of routes, backend logic, and error handling.

import supranim/microservice

type
  MemoryCacheMessage* = enum
    entryNotFound
    storageNotFound
    storageNameExists

initService Cache[WebService]:
  # threads = 0
    # Number of threads for running the WebService
  description = "A fast in-memory cache Service Provider for Supranim"
    # A description of the Service Provider

  # Define ServiceProvider routes
  routes do:
    # `GET /` is a reserved route path for returning routes index.
    # Also, the other verbs are disabled for this path.

    post "/storage/{bucket:slug}":
      ## Create a new CacheStorage
      let bucket = req.params["bucket"]
      if likely(not Memcache.storages.hasKey(bucket)):
        Memcache.storages[bucket] =
          CacheStorage(createdAt: now(), lastUpdated: now())
        req.respond(201)
      req.respond(409, newError(HttpCode(409), storageNameExists.ord, bucket))

    put "/storage/{bucket:slug}/cache/{key:slug}":
      ## Store a new cache entry by key
      let
        bucket = req.params["bucket"]
        key = req.params["key"]
      withStorage bucket:
        storage.entries[req.params["key"]] = CacheEntry(data: "Yellow")
        storage.lastUpdated = now()
        req.respond(201)

    get "/storage/{bucket:slug}/cache/{key:slug}":
      ## Retrieve a cache entry by key
      let
        bucket = req.params["bucket"]
        key = req.params["key"]
      withStorage bucket:
        withEntry key:
          req.respond(cacheEntry.data)

    patch "/storage/{name:slug}/cache/{key:slug}":
      ## Modify data of a cache entry by key
      let
        bucket = req.params["bucket"]
        key = req.params["key"]
      withStorage bucket:
        withEntry key:
          cacheEntry.data = ""
          storage.lastUpdated = now()
          req.respond(204)

    delete "/storage/{bucket:slug}/cache/{key:slug}":
      ## Delete a cache entry by key from CacheStorage
      let
        bucket = req.params["bucket"]
        key = req.params["key"]
      withStorage bucket:
        withEntry key:
          # Memcache.data.excl(key)
          req.respond(202)

    post "/storage/{bucket:slug}/flush":
      ## Clear all entries from a specific CacheStorage
      discard

    get "/storage":
      ## Returns a JSON object of CacheStorage
      let x = newJObject()
      for key, storage in Memcache.storages:
        x[key] = %*{
          "length": storage.entries.len,
          "created_at": $(storage.createdAt),
          "updated_at": $(storage.lastUpdated)
        }
      req.respond(200, x)

  backend do:
    # Define your backend logic. Basically, code inside
    # `backend` block translates to `when isMainModule`.
    import std/times
    import pkg/flatty

    type
      CacheEntry* = ref object
        data: string
        expiration: Option[DateTime]

      CacheStorage* = ref object
        entries: CritBitTree[CacheEntry]
        createdAt, lastUpdated: DateTime

      MemoryCache* {.acyclic.} = ref object
        storages: TableRef[string, CacheStorage]
          # A ref table holding instances of `CacheStorage`
    
    var Memcache: MemoryCache =
      MemoryCache(
        storages: newTable[string, CacheStorage]()
      )

    proc dumpHook*[T](s: var string; val: CacheEntry) =
      ## A custom dump hook for serializing `CacheEntry` to string.
      s.add("{data: " & val.data & ", expiration: " &
        (if val.expiration.isSome: $(val.expiration.get()) else: "none") & "}")

    proc hasStorage(m: var MemoryCache, name: string): bool =
      # Check if a storage exists for given `name`
      result = m.storages.hasKey(name)

    proc getStorage(m: var MemoryCache, name: string): CacheStorage =
      # Returns a `CacheStorage` by name
      result = m.storages[name]

    template withStorage(storageName: string, code: untyped) {.dirty.} =
      if Memcache.storages.hasKey(storageName):
        let storage: CacheStorage = Memcache.storages[storageName]
        code
      req.error(404, notFound(storageNotFound.ord, storageName))
    
    template withEntry(entryKey: string, code: untyped) {.dirty.} =
      if storage.entries.hasKey(entryKey):
        let cacheEntry: CacheEntry = storage.entries[entrykey]
        code
      req.error(404, notFound(entryNotFound.ord, entryKey))

  # client do:
  #   # Optionally, add extra client-side functionality.
  #   # Code inside `client` block becomes available when
  #   # importing the Service Provider in a Supranim application.
  #   #
  #   # The ServiceManager generates a HTTP client based on available
  #   # route paths
  #   discard
  