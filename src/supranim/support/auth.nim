import pkg/valido
import pkg/libsodium/[sodium, sodium_sizes]

proc hashPassword*(pw: string): string =
  crypto_pwhash_str(pw)

proc checkPassword*(pw, hash: string): bool =
  crypto_pwhash_str_verify(hash, pw)