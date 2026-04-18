#
# Supranim is a high-performance web framework for building
# web applications and microservices in Nim
# 
#   (c) 2026 LGPL-v3-or-later License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#

# Malloc trim shim
# Cross-platform: Linux (glibc) + macOS (libmalloc)
# todo windows?

const
  MaxReqResSize* = 1_048_576 # 1MB - todo expose to config?

when defined(macosx):
  type
    MallocZoneT* = object ## Opaque; libmalloc internal
    MallocZone*  = ptr MallocZoneT

  proc malloc_default_zone*(): MallocZone
    {.cdecl, importc: "malloc_default_zone", header: "<malloc/malloc.h>".}

  proc malloc_zone_pressure_relief*(zone: MallocZone; goal: csize_t): csize_t
    {.cdecl, importc: "malloc_zone_pressure_relief", header: "<malloc/malloc.h>".}

  ## macOS note:
  ## malloc_zone_pressure_relief may return 0 even when pages are actually reclaimed.
  ## So this shim reports whether trim was attempted.
  proc malloc_trim*(pad: csize_t = 0): bool =
    discard malloc_zone_pressure_relief(malloc_default_zone(), pad)
    result = true

  proc releaseUnusedMemory*(): bool =
    malloc_trim(0)

elif defined(linux):
  # int malloc_trim(size_t pad); nonzero on success
  proc glibc_malloc_trim(pad: csize_t): cint
    {.cdecl, importc: "malloc_trim", header: "<malloc.h>".}

  proc malloc_trim*(pad: csize_t = 0): bool =
    glibc_malloc_trim(pad) != 0

  proc releaseUnusedMemory*(): bool =
    malloc_trim(0)

else:
  proc malloc_trim*(pad: csize_t = 0): bool = false
  proc releaseUnusedMemory*(): bool = false

template freemem*(x: untyped) =
  {.gcsafe.}:
    discard releaseUnusedMemory()

  