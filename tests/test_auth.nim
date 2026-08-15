#
# Unit tests for supranim/support/auth (backed by pkg/nimcypher)
#
import std/unittest
import std/strutils

import supranim/support/auth

suite "support/auth":
  test "boxKeys returns a valid X25519 keypair":
    let (publicKey, secretKey) = boxKeys()
    check publicKey.len == 64
    check secretKey.len == 64
    check publicKey != secretKey

  test "boxKeys generates unique keypairs":
    check boxKeys() != boxKeys()

  test "signKeys returns a valid Ed25519 keypair":
    let (publicKey, secretKey) = signKeys()
    check publicKey.len == 64
    check secretKey.len == 128
    check publicKey != secretKey

  test "signKeys generates unique keypairs":
    check signKeys() != signKeys()

  test "generateToken returns a 64-char hex token":
    let token = generateToken()
    check token.len == 64
    for c in token:
      check c in {'0'..'9', 'a'..'f', 'A'..'F'}

  test "generateToken(byteLen) honors the requested length":
    check generateToken(16).len == 32
    check generateToken(8).len == 16

  test "generateToken is unique":
    check generateToken() != generateToken()

  test "signMessage and verifySignature round-trip":
    let (publicKey, secretKey) = signKeys()
    let signature = signMessage("hello supranim", secretKey)
    check signature.len == 128
    check verifySignature("hello supranim", publicKey, signature)

  test "verifySignature rejects a tampered message":
    let (publicKey, secretKey) = signKeys()
    let signature = signMessage("hello supranim", secretKey)
    check not verifySignature("hello supranim!", publicKey, signature)

  test "verifySignature rejects a signature from another key":
    let (publicKey, _) = signKeys()
    let (_, otherSecretKey) = signKeys()
    let signature = signMessage("hello supranim", otherSecretKey)
    check not verifySignature("hello supranim", publicKey, signature)

  test "sealMessage and unsealMessage round-trip":
    let key = randomBytes[32]().toHex
    let sealed = sealMessage("secret payload", key)
    check sealed.count(':') == 2
    check unsealMessage(sealed, key) == "secret payload"

  test "unsealMessage rejects a tampered ciphertext":
    let key = randomBytes[32]().toHex
    let sealed = sealMessage("secret payload", key)
    let tampered = sealed[0 .. ^2] & (if sealed[^1] == '0': '1' else: '0')
    expect ValueError:
      discard unsealMessage(tampered, key)

  test "unsealMessage rejects a wrong key":
    let sealed = sealMessage("secret payload", randomBytes[32]().toHex)
    expect ValueError:
      discard unsealMessage(sealed, randomBytes[32]().toHex)

  test "unsealMessage rejects malformed input":
    expect ValueError:
      discard unsealMessage("not-a-sealed-message", randomBytes[32]().toHex)
