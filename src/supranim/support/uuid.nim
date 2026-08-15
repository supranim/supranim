#
# Supranim is a high-performance web framework for building
# web applications and microservices in Nim
# 
#   (c) 2026 LGPL-v3-or-later License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#

## UUID support backed by the complete `pkg/openparser/uuid` module
## (RFC 4122 versions 1-8). Importing this module re-exports the full
## openparser UUID API: `Uuid`, `UuidBytes`, `UuidVersion`, `UuidVariant`,
## `UuidNamespace`, `UuidError`, `parseUuid`, `isValidUuid`, `version`,
## `variant`, `isNil`, `newUuidV1..V8` (and `v1..v8` aliases), `nilUuid`,
## `==`, `hash` and `$`.

import pkg/openparser/uuid
export uuid
