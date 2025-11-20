# Supranim is a simple MVC-style web framework for building
# fast web applications, REST API microservices and other cool things.
#
#     (c) 2024 George Lemon | MIT License
#     Made by Humans from OpenPeeps
#     https://github.com/supranim/supranim

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