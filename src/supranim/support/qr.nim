# Supranim is a lightweight, high-performance MVC framework for Nim,
# designed to simplify the development of web applications and REST APIs.
#
# It features intuitive routing, modular architecture, and built-in support
# for modern web standards, making it easy to build scalable and maintainable
# projects.
#
# (c) 2025 Supranim | MIT License
#     Made by Humans from OpenPeeps
#     https://supranim.com | https://github.com/supranim

import std/[strutils]
import pkg/[otp, qr, base32]

type
  OtpType* = enum
    otpHotp = "hotp" # counter based OTP
    otpTotp = "totp" # time based OTP

const otpauth = "otpauth://$1/$2?secret=$3&period=$4"

proc gen2FACode*(secret, label: sink string,
    issuer: string = "", interval: uint = 30, otpType = OtpType.otpTotp): string = 
  ## Generate a new QR Code for 2FA (Two Factor Authentication)
  var x = otpauth % [$(otpType), label, secret, $interval]
  if issuer.len > 0:
    add x, "&issuer=" & issuer
  result = qrSVG(x, "test.svg")

proc genQR*(x: string): string =
  ## Generate a generic QR Code from `x` string
  qrSVG(x)

# when isMainModule:
#   import std/times
#   gen2FACode("loremipsum", "MyLabel", "Vasco")
#   var totp = Totp.init("loremipsum")
#   echo totp.now()
#   echo totp.verify(853136, getTime().toUnix)