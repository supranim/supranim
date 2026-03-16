#
# Supranim is a full-featured web framework for building
# web apps & microservices in Nim.
# 
#   (c) 2026 LGPL-v3-or-later License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#

## This module provides a simple and efficient way to generate unique IDs,
## inspired by the popular NanoID library. It uses a customizable alphabet
## and allows you to specify the length of the generated ID. The implementation is
## designed to be fast and secure, making it suitable for various use cases such as database keys,
## session identifiers, or any scenario where a unique identifier is needed.
## 
## Originally written by [Anirudh Oppiliappan](https://github.com/icyphox/nanoid.nim)
import std/[math, lenientops, sysrand]

const
  masks = [15, 31, 63, 127, 255]
  defaultAlphabet* = "_-0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"

proc generate*(alphabet: string = defaultAlphabet,
                size: int = 21): string =
  ## Generates a unique ID using the specified alphabet and size.
  if alphabet == "" or size < 1:
    return # invalid parameters
  var mask: int = 1
  for m in masks:
    if m >= len(alphabet) - 1:
      mask = m
      break

  var step = int(ceil(1.6 * mask * size / len(alphabet)))
  while true:
    var randomBytes: seq[byte]
    randomBytes = urandom(step)
    for i in countUp(0, step-1):
      var randByte = randomBytes[i].int and mask
      if randByte < len(alphabet):
        if alphabet[randByte] in alphabet:
          result.add(alphabet[randByte])
          if len(result) >= size:
            return # returns the generated ID from `result`