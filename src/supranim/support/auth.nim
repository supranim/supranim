import pkg/valido
import pkg/libsodium/[sodium, sodium_sizes]

export bin2hex

proc hashPassword*(pw: string): string =
  ## Hashes the password using libsodium.
  crypto_pwhash_str(pw)

proc checkPassword*(pw, hash: string): bool =
  ## Checks if the password matches the hash.
  crypto_pwhash_str_verify(hash, pw)

proc boxKeys*: (string, string) =
  ## Generates a new keypair
  let (pk, sk) = crypto_box_keypair()
  result = (pk.bin2hex, sk.bin2hex)

proc boxRandomBytes*: string =
  randombytes(crypto_box_NONCEBYTES())

proc boxEncrypt*(msg, pk, sk: string): string =
  ## Encrypts a message using the public key
  ## and the secret key.
  let nonce = boxRandomBytes()
  return crypto_box_easy(msg, nonce, pk, sk).bin2hex