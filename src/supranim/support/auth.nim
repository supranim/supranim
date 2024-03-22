import pkg/libsodium/[sodium, sodium_sizes]

proc hash*(pw: string): string =
  crypto_pwhash_str(pw)

proc check*(pw, hash: string): bool =
  crypto_pwhash_str_verify(hash, pw)