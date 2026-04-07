#
# Supranim is a full-featured web framework for building
# web apps & microservices in Nim.
# 
#   (c) 2026 LGPL-v3-or-later License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#
import pkg/e2ee
export e2ee

proc boxKeys*: (string, string) =
  ## Generates a new X25519 keypair (private, public), both as hex strings
  let secret = randomBytes[32]()
  let (sk, pk) = x25519KeyPair(secret)
  result = (pk.toHex, sk.toHex)

proc signKeys*: (string, string) =
  ## Generates a new Ed25519 signing keypair (public, secret), both as hex strings
  let kp = generateSigningKeyPair()
  result = (publicKeyToHex(kp.publicKey), secretKeyToHex(kp.secretKey))