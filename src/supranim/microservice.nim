#
# Supranim is a high-performance web framework for building
# web applications and microservices in Nim
# 
#   (c) 2026 LGPL-v3-or-later License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#

## Microservice entry point.
## Re-exports `supranim/core/services` for defining `ServiceType` providers.

import supranim/core/services
export services