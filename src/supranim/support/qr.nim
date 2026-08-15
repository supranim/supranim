#
# Supranim is a high-performance web framework for building
# web applications and microservices in Nim
# 
#   (c) 2026 LGPL-v3-or-later License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#

## QR code and 2FA support backed by `pkg/twofa`. Importing this module
## re-exports the full twofa API: `initTotp`, `initHotp`, `provisioningUri`,
## `saveQr`, `getQr`, plus the `otp`, `base32` and `qr` modules.

import pkg/twofa
export twofa
