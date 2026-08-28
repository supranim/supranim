#
# Supranim is a high-performance web framework for building
# web applications and microservices in Nim
# 
#   (c) 2026 LGPL-v3-or-later License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#

## This service implements a durable cache backed by the Boogie KV store.
## Each named storage (bucket) maps to a prefix in a single WAL-backed
## KvStore at `storage/cache`. Entries are serialized with `flatty` and
## carry an optional expiry timestamp. Expired entries are lazily evicted
## on read.
##
## Routes:
##   POST   /storage/{bucket:slug}                     — create bucket
##   PUT    /storage/{bucket:slug}/cache/{key:slug}    — store entry (body is value, optional `ttl` query param in seconds)
##   GET    /storage/{bucket:slug}/cache/{key:slug}    — retrieve entry
##   PATCH  /storage/{bucket:slug}/cache/{key:slug}    — update entry
##   DELETE /storage/{bucket:slug}/cache/{key:slug}    — delete entry
##   POST   /storage/{bucket:slug}/flush               — clear bucket
##   GET    /storage                                    — list buckets

import supranim/microservice

type
  MemoryCacheMessage* = enum
    entryNotFound
    storageNotFound
    storageNameExists

initService Cache[WebService]:
  description = "A durable cache Service Provider backed by Boogie KV store"
    # A description of the Service Provider

  routes do:
    post "/storage/{bucket:slug}":
      ## Create a new cache bucket
      let bucket = req.params["bucket"]
      if likely(not hasBucket(bucket)):
        CacheKv.put(bucketMarker(bucket), $now().toTime.toUnix)
        req.respond(201)
      req.respond(409, newError(HttpCode(409), storageNameExists.ord, bucket))

    put "/storage/{bucket:slug}/cache/{key:slug}":
      ## Store a cache entry by key. Body is stored as value.
      ## Query param `ttl` (seconds) sets an expiry, e.g. `?ttl=3600`.
      let
        bucket = req.params["bucket"]
        key = req.params["key"]
      withStorage bucket:
        let bodyStr =
          if req.getBody.isSome and req.getBody.get.len > 0:
            req.getBody.get
          else: "Yellow"
        var ttlOpt: Option[int64] = none(int64)
        let ttlHeader = req.findHeader("x-cache-ttl")
        if ttlHeader.len > 0:
          try: ttlOpt = some(parseInt(ttlHeader).int64) except: discard
        else:
          let q = req.getQuery()
          if q.hasKey("ttl"):
            try: ttlOpt = some(parseInt(q["ttl"]).int64) except: discard
        var expiresAt: Option[int64] = none(int64)
        if ttlOpt.isSome:
          expiresAt = some(now().toTime.toUnix + ttlOpt.get)
        let entry = CacheEntry(data: bodyStr, expiresAt: expiresAt)
        CacheKv.put(bucketKey(bucket, key), toFlatty(entry))
        req.respond(201)

    get "/storage/{bucket:slug}/cache/{key:slug}":
      ## Retrieve a cache entry by key
      let
        bucket = req.params["bucket"]
        key = req.params["key"]
      withStorage bucket:
        withEntry key:
          req.respond(cacheEntry.data)

    patch "/storage/{bucket:slug}/cache/{key:slug}":
      ## Modify data of a cache entry by key
      let
        bucket = req.params["bucket"]
        key = req.params["key"]
      withStorage bucket:
        withEntry key:
          let bodyStr =
            if req.getBody.isSome and req.getBody.get.len > 0:
              req.getBody.get
            else: cacheEntry.data
          cacheEntry.data = bodyStr
          CacheKv.put(bucketKey(bucket, key), toFlatty(cacheEntry))
          req.respond(204)

    delete "/storage/{bucket:slug}/cache/{key:slug}":
      ## Delete a cache entry by key from bucket
      let
        bucket = req.params["bucket"]
        key = req.params["key"]
      withStorage bucket:
        withEntry key:
          discard CacheKv.delete(bucketKey(bucket, key))
          req.respond(202)

    post "/storage/{bucket:slug}/flush":
      ## Clear all entries from a specific bucket
      let bucket = req.params["bucket"]
      withStorage bucket:
        var toDelete: seq[string]
        for k, _ in CacheKv.pairsUnordered:
          if k.startsWith(bucket & ":"):
            toDelete.add(k)
        for k in toDelete:
          discard CacheKv.delete(k)
        req.respond(202)

    get "/storage":
      ## Returns a JSON object of buckets with entry counts
      let x = newJObject()
      var buckets = initTable[string, int]()
      var createdAt = initTable[string, string]()
      for k, v in CacheKv.pairsUnordered:
        if k.startsWith("__bucket:"):
          let b = k[9..^1]
          buckets[b] = 0
          createdAt[b] = v
        elif ":" in k:
          let bucket = k.split(':', 1)[0]
          # skip expired entries lazily
          try:
            let e = fromFlatty(v, CacheEntry)
            if not e.isExpired:
              buckets.mgetOrPut(bucket, 0) += 1
          except:
            buckets.mgetOrPut(bucket, 0) += 1
      for bucket, count in buckets:
        x[bucket] = %*{
          "length": count,
          "created_at": createdAt.getOrDefault(bucket, "")
        }
      req.respond(200, x)

  backend do:
    import std/[times, options, tables, json, os, strutils, sequtils]
    import pkg/flatty
    import pkg/boogie/stores/kv
    import pkg/supranim/core/paths

    type
      CacheEntry* = object
        data: string
        expiresAt: Option[int64]

    proc isExpired*(e: CacheEntry): bool =
      ## Check if a cache entry has expired based on its `expiresAt` timestamp.
      if e.expiresAt.isSome:
        return now().toTime.toUnix > e.expiresAt.get
      false

    # Durable KV store at storage/cache (WAL + checkpoint every 100 ops, flush every 1000)
    discard existsOrCreateDir(storagePath)
    var CacheKv* = newKvStore(storagePath / "cache", ksmDisk, enableWal = true,
                              checkpointEveryOps = 100'u32, walFlushEveryOps = 1000'u32)

    proc bucketMarker*(bucket: string): string =
      ## Internal key marking bucket existence.
      "__bucket:" & bucket

    proc bucketKey*(bucket, key: string): string =
      ## Composite key for a bucket entry.
      bucket & ":" & key

    proc hasBucket*(bucket: string): bool =
      ## Check if a bucket exists.
      CacheKv.hasKey(bucketMarker(bucket))

    template withStorage*(storageName: string, code: untyped) {.dirty.} =
      ## Guard that ensures the bucket exists, else 404.
      if hasBucket(storageName):
        code
      else:
        req.error(404, notFound(storageNotFound.ord, storageName))

    template withEntry*(entryKey: string, code: untyped) {.dirty.} =
      ## Guard that ensures the entry exists and is not expired.
      let ckey = bucketKey(bucket, entryKey)
      if CacheKv.hasKey(ckey):
        let raw = CacheKv.get(ckey)
        if raw.isSome:
          var cacheEntry: CacheEntry
          var expired = false
          try:
            cacheEntry = fromFlatty(raw.get, CacheEntry)
            if cacheEntry.isExpired:
              discard CacheKv.delete(ckey)
              expired = true
          except:
            cacheEntry = CacheEntry(data: raw.get, expiresAt: none(int64))
          if expired:
            req.error(404, notFound(entryNotFound.ord, entryKey))
          else:
            code
        else:
          req.error(404, notFound(entryNotFound.ord, entryKey))
      else:
        req.error(404, notFound(entryNotFound.ord, entryKey))
