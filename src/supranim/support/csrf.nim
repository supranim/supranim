# Supranim is a simple MVC-style web framework for building
# fast web applications, REST API microservices and other cool things.
#
# (c) 2022 Supranim is released under MIT License
#          Made by Humans from OpenPeep
#          https://supranim.com | https://github.com/supranim

import nimcrypto
import std/[tables, times]

from std/httpcore import `$`, HttpCode
from std/sysrand import urandom
from std/strutils import toHex, toLowerAscii

export `$`, times, HttpCode

type
    TokenState* = enum
        InvalidToken, ExpiredToken, UsedToken, NewToken

    Token* = object
        state: TokenState
        key: string
        created: DateTime

    SecurityTokens = object
        tokens: TableRef[string, Token]
        ttl: Duration

when compileOption("threads"):
    var Csrf* {.threadvar.}: SecurityTokens
else:
    var Csrf*: SecurityTokens

proc init*(this: var SecurityTokens, ttl = initDuration(minutes = 60)) =
    ## Initialize a `Csrf` singleton
    Csrf = SecurityTokens(tokens: newTable[string, Token](), ttl: ttl)

method newToken*(this: var SecurityTokens): Token =
    ## Generate a new CSRF token
    var randBytes = newSeq[byte](32)
    discard urandom(randBytes)
    let key = toLowerAscii($digest(sha1, randBytes.toHex))
    result = Token(state: NewToken, key: key, created: now())
    this.tokens[key] = result

method checkToken*(this: var SecurityTokens, token: string): TokenState =
    ## Check a string token and determine its state.
    ## Invalid or non existing tokens will return `InvalidToken`.
    if this.tokens.hasKey token:
        if now() - this.tokens[token].created >= this.ttl:
            return ExpiredToken
        result = this.tokens[token].state

method isValid*(this: var SecurityTokens, token: string): bool =
    ## Validates a string token.
    ## TODO create a csrf middleware to handle 403 responses
    let tokenState = this.checkToken(token)
    result = tokenState == NewToken

method use*(this: var SecurityTokens, token: string): HttpCode =
    ## Use the given token and change its state
    if this.isValid token:
        this.tokens[token].state = UsedToken
        result = HttpCode(200)
    else:
        result = HttpCode(403)

method use*(this: var SecurityTokens, token: Token): HttpCode =
    result = use(this, token.key)

method `$`*(token: Token): string =
    result = token.key

method flush*(this: var SecurityTokens) =
    ## Flush all tokens that have been used or expired.
    var trash: seq[string]
    for k, i in pairs(this.tokens):
        if i.state in {UsedToken, ExpiredToken}:
            trash.add k
    for token in trash:
        this.tokens.del(token)