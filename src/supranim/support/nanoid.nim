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

import std/[math, lenientops, sysrand]

const
  masks = [15, 31, 63, 127, 255]
  defaultAlphabet = "_-0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"

proc generate*(alphabet: string = defaultAlphabet,
                size: int = 21): string =
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
