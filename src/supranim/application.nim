#
# Supranim is a high-performance web framework for building
# web applications and microservices in Nim
# 
#   (c) 2026 LGPL-v3-or-later License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#

## Re-export of the core application singleton.
## Import `supranim/application` to access `App`, `init`, `port`, and lifecycle helpers.

import ./core/application
export application