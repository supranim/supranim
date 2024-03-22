import pkg/libsodium/[sodium, sodium_sizes]

export bin2hex, hex2bin

type
  CryptoBoxPublicKey* = string
  CryptoBoxSecretKey* = string

proc nonce*(): string =
  randombytes(crypto_box_NONCEBYTES())

proc encryptbox*(x, nonce: string, pk: CryptoBoxPublicKey, sk: CryptoBoxSecretKey): string =
  crypto_box_easy(x, nonce, pk, sk)