# Supranim is a simple MVC-style web framework for building
# fast web applications, REST API microservices and other cool things.
#
# (c) 2022 Supranim is released under MIT License
#          Made by Humans from OpenPeep
#          https://supranim.com | https://github.com/supranim

import pkginfo

when requires "nimcrypto":
    import nimcrypto
else:
    {.error: "CSRF module requires nimcrypto".}

import std/[tables, times]

from std/sysrand import urandom
from std/strutils import toHex, toLowerAscii

type
    TokenState* = enum
        InvalidToken, ExpiredToken, UsedToken, NewToken

    Token* = tuple[state: TokenState, token: string]

    SecurityTokens = object
        tokens: TableRef[string, Token]

when compileOption("threads"):
    var Csrf* {.threadvar.}: SecurityTokens
else:
    var Csrf*: SecurityTokens

proc init*(this: var SecurityTokens) =
    Csrf = SecurityTokens(tokens: newTable[string, Token]())

proc randomBytesSeq*(size = 32): seq[byte] {.inline.} =
    ## Generates a new system random sequence of bytes.
    result = newSeq[byte](size)
    discard urandom(result)

method newToken*(this: var SecurityTokens): string =
    ## Generate a new CSRF token
    var randBytes = newSeq[byte](32)
    discard urandom(randBytes)
    result = toLowerAscii($digest(sha1, randBytes.toHex))
    this.tokens[result] = (state: NewToken, token: result)

method checkToken*(this: var SecurityTokens, token: string): TokenState =
    ## Check a string token and determine its state. Non existing tokens
    ## will return `InvalidToken`.
    if this.tokens.hasKey token:
        result = this.tokens[token].state

method getTokenState*(this: var SecurityTokens, token: string): TokenState =
    ## Alias of `checkToken` method
    result = this.checkToken token

method isValid*(this: var SecurityTokens, token: string): bool =
    ## Validates a string token.
    let tokenState = this.checkToken(token)
    result = tokenState == NewToken

method use*(this: var SecurityTokens, token: string) =
    ## Use the given token and change its state
    if this.isValid token:
        this.tokens[token].state = UsedToken

method flush*(this: var SecurityTokens) =
    ## Flush all tokens that have been used or expired.
    var trash: seq[string]
    for k, i in pairs(this.tokens):
        if i.state in {UsedToken, ExpiredToken}:
            trash.add k
    for token in trash:
        this.tokens.del(token)
