# Supranim is a lightweight, high-performance MVC framework for Nim,
# designed to simplify the development of web applications and REST APIs.
#
# It features intuitive routing, modular architecture, and built-in support
# for modern web standards, making it easy to build scalable and maintainable
# projects.
#
# (c) 2025 Supranim | MIT License
#      Made by Humans from OpenPeeps
#      https://supranim.com | https://github.com/supranim

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

proc init*(csrfManager: var SecurityTokens, ttl = initDuration(minutes = 60)) =
  ## Initialize a `Csrf` singleton
  Csrf = SecurityTokens(tokens: newTable[string, Token](), ttl: ttl)

proc newToken*(csrfManager: var SecurityTokens): Token =
  ## Generate a new CSRF token
  var randBytes = newSeq[byte](32)
  discard urandom(randBytes)
  let key = toLowerAscii($digest(sha1, randBytes.toHex))
  result = Token(state: NewToken, key: key, created: now())
  csrfManager.tokens[key] = result

proc checkToken*(csrfManager: var SecurityTokens, token: string): TokenState =
  ## Check a string token and determine its state.
  ## Invalid or non existing tokens will return `InvalidToken`.
  if csrfManager.tokens.hasKey token:
    if now() - csrfManager.tokens[token].created >= csrfManager.ttl:
      return ExpiredToken
    result = csrfManager.tokens[token].state

proc isValid*(csrfManager: var SecurityTokens, token: string): bool =
  ## Validates a string token.
  ## TODO create a csrf middleware to handle 403 responses
  let tokenState = csrfManager.checkToken(token)
  result = tokenState == NewToken

proc use*(csrfManager: var SecurityTokens, token: string): HttpCode =
  ## Use the given token and change its state
  if csrfManager.isValid token:
    csrfManager.tokens[token].state = UsedToken
    result = HttpCode(200)
  else:
    result = HttpCode(403)

proc use*(csrfManager: var SecurityTokens, token: Token): HttpCode =
  result = use(this, token.key)

proc `$`*(token: Token): string =
  result = token.key

proc flush*(csrfManager: var SecurityTokens) =
  ## Flush all tokens that have been used or expired.
  var trash: seq[string]
  for k, i in pairs(csrfManager.tokens):
    if i.state in {UsedToken, ExpiredToken}:
      trash.add k
  for token in trash:
    csrfManager.tokens.del(token)