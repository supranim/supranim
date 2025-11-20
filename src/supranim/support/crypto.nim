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

import pkg/libsodium/[sodium, sodium_sizes]
export bin2hex, hex2bin

#
# Libsodium
#

proc random*(size: int = 32): string =
  ## Generate random bytes using libsodium `randombytes`
  ## and return the string representation
  bin2hex(randombytes(size))

type
  CryptoBoxPublicKey* = string
  CryptoBoxSecretKey* = string

proc nonce*(): string =
  randombytes(crypto_box_NONCEBYTES())

proc encryptbox*(x, nonce: string, pk: CryptoBoxPublicKey, sk: CryptoBoxSecretKey): string =
  crypto_box_easy(x, nonce, pk, sk)
