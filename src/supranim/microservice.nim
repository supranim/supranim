#
# Supranim is a high-performance web framework for building
# web applications and microservices in Nim
# 
#   (c) 2026 LGPL-v3-or-later License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#

## Microservice entry point.
## Re-exports `supranim/core/services` for defining `ServiceType` providers
## plus `supranim/network/websocket` for `ws do:` blocks.

import supranim/core/services
import supranim/network/websocket
export services
export websocket