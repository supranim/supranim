#
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

## Authentication and cryptography helpers backed by `pkg/nimcypher` (a pure-Nim
## port of Monocypher). Provides high-level utilities for authentication and
## end-to-end security: X25519 (`boxKeys`) and Ed25519 (`signKeys`) keypair
## generation, secure random tokens (`generateToken`), message signing and
## signature verification (`signMessage` / `verifySignature`), and sealed
## XChaCha20-Poly1305 encryption (`sealMessage` / `unsealMessage`). The full
## nimcypher API (hashing, AEAD, key exchange, password hashing, constant-time
## helpers) is re-exported through `export nimcypher`.

import std/strutils

import pkg/nimcypher
export nimcypher

proc boxKeys*: (string, string) =
  ## Generates a new X25519 keypair as hex strings.
  ## Returns `(publicKey, secretKey)`.
  let (secretKey, publicKey) = x25519KeyPair()
  result = (publicKey.toHex, secretKey.toHex)

proc signKeys*: (string, string) =
  ## Generates a new Ed25519 signing keypair as hex strings.
  ## Returns `(publicKey, secretKey)`.
  let kp = generateSigningKeyPair()
  result = (publicKeyToHex(kp.publicKey), secretKeyToHex(kp.secretKey))

proc generateToken*(): string =
  ## Generates a cryptographically-secure random token as a hex string,
  ## useful for API keys, CSRF tokens and session identifiers.
  randomBytes[32]().toHex

proc generateToken*(byteLen: static int): string =
  ## Generates a random token of `byteLen` random bytes as a hex string.
  randomBytes[byteLen]().toHex

proc signMessage*(message: string, secretKeyHex: string): string =
  ## Signs `message` with an Ed25519 secret key (hex string) and returns
  ## the signature as a hex string.
  signatureToHex(sign(secretKeyFromHex(secretKeyHex), message))

proc verifySignature*(message: string, publicKeyHex, signatureHex: string): bool =
  ## Verifies an Ed25519 signature (hex strings) against `message`.
  verify(publicKeyFromHex(publicKeyHex), message, signatureFromHex(signatureHex))

proc hexToBytes(s: string): seq[byte] =
  if s.len mod 2 != 0:
    raise newException(ValueError, "invalid hex string")
  result = newSeq[byte](s.len div 2)
  for i in 0 ..< result.len:
    result[i] = parseHexInt(s[i * 2 .. i * 2 + 1]).uint8

proc sealMessage*(message: string, keyHex: string): string =
  ## Encrypts and authenticates `message` with XChaCha20-Poly1305 using a
  ## 32-byte key (hex string). Returns "hex(nonce):hex(mac):hex(ciphertext)".
  let sealed = seal(message, fromHex[32, uint8](keyHex))
  result = sealed.nonce.toHex & ":" & sealed.mac.toHex & ":" & sealed.cipherText.toHex

proc unsealMessage*(sealed: string, keyHex: string): string =
  ## Decrypts a message produced by `sealMessage`. Raises `ValueError` if
  ## the MAC does not verify.
  let parts = sealed.split(":")
  if parts.len != 3:
    raise newException(ValueError, "invalid sealed message format")
  let msg = SealedMessage(
    nonce: fromHex[24, uint8](parts[0]),
    mac: fromHex[16, uint8](parts[1]),
    cipherText: hexToBytes(parts[2])
  )
  toString(unseal(msg, fromHex[32, uint8](keyHex)))
