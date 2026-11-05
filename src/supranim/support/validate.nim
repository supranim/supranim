#
# Supranim is a high-performance web framework for building
# web applications and microservices in Nim
#
#   (c) 2026 LGPL-v3-or-later License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#

## Minimal request validation for Supranim core.
##
## This module fills the validation gap: previously only
## `support/scanner.nim` regex helpers existed, with no form/request
## validator. It provides a small, dependency-free rule engine over
## `TableRef[string, string]` (as returned by `getFields` /
## `getQueryTable`).
##
## For advanced validation (IDN, IBAN, EAN, ports, full URI schemes,
## strong-password entropy) use `pkg/valido` and `pkg/bag`
## (`withValidator`) — this core validator covers the common web
## cases without adding dependencies.

import std/[options, tables, strutils]

import ./scanner

type
  ValidationRuleKind* = enum
    vrRequired
      ## Field must be present and non-empty after stripping.
    vrEmail
      ## Must be a valid email (`scanner.isEmail`).
    vrMinLen
      ## `paramInt` = minimum length.
    vrMaxLen
      ## `paramInt` = maximum length.
    vrEqualsField
      ## Must equal the value of another field (`paramStr` = other field).
    vrStrongPassword
      ## Min 8 chars with lower, upper and digit (see `isStrongPasswordStr`).
    vrNumeric
      ## All chars digits (optional leading `-`).
    vrInt
      ## Parseable via `parseInt`.
    vrAlphaNum
      ## Letters + digits only.
    vrSlug
      ## Valid slug (`scanner.isSlug`).
    vrUuid
      ## Valid UUID (`scanner.isUUID`).
    vrCustom
      ## Custom callback (`custom` must be set). `paramStr` is free-form context.

  ValidationRule* = object
    field*: string
    kind*: ValidationRuleKind
    paramInt*: int
    paramStr*: string
    message*: string
    custom*: proc(value: string,
      fields: TableRef[string, string]): bool {.closure.}

  ValidationError* = object
    field*: string
    rule*: ValidationRuleKind
    message*: string

  ValidationResult* = object
    ok*: bool
    errors*: seq[ValidationError]
    values*: TableRef[string, string]

proc isStrongPasswordStr*(s: string, minLen = 8): bool =
  ## Minimal strong-password check without extra dependencies:
  ## length + lower + upper + digit. For entropy-based scoring use
  ## `valido.isStrongPassword` (blackpaper backend).
  if s.len < minLen: return false
  var hasLower, hasUpper, hasDigit: bool
  for c in s:
    if c in {'a'..'z'}: hasLower = true
    elif c in {'A'..'Z'}: hasUpper = true
    elif c in {'0'..'9'}: hasDigit = true
    if hasLower and hasUpper and hasDigit: return true
  false

proc required*(field: string, message = ""): ValidationRule =
  ValidationRule(field: field, kind: vrRequired,
    message: if message.len > 0: message else: field & " is required")

proc email*(field: string, message = ""): ValidationRule =
  ValidationRule(field: field, kind: vrEmail,
    message: if message.len > 0: message else: field & " must be a valid email")

proc minLen*(field: string, n: int, message = ""): ValidationRule =
  ValidationRule(field: field, kind: vrMinLen, paramInt: n,
    message: if message.len > 0: message else: field & " must be at least " & $n & " chars")

proc maxLen*(field: string, n: int, message = ""): ValidationRule =
  ValidationRule(field: field, kind: vrMaxLen, paramInt: n,
    message: if message.len > 0: message else: field & " must be at most " & $n & " chars")

proc equalsField*(field, other: string, message = ""): ValidationRule =
  ValidationRule(field: field, kind: vrEqualsField, paramStr: other,
    message: if message.len > 0: message else: field & " must match " & other)

proc strongPassword*(field: string, message = ""): ValidationRule =
  ValidationRule(field: field, kind: vrStrongPassword,
    message: if message.len > 0: message else: field & " is not strong enough")

proc numeric*(field: string, message = ""): ValidationRule =
  ValidationRule(field: field, kind: vrNumeric,
    message: if message.len > 0: message else: field & " must be numeric")

proc slugRule*(field: string, message = ""): ValidationRule =
  ValidationRule(field: field, kind: vrSlug,
    message: if message.len > 0: message else: field & " must be a valid slug")

proc uuidRule*(field: string, message = ""): ValidationRule =
  ValidationRule(field: field, kind: vrUuid,
    message: if message.len > 0: message else: field & " must be a valid UUID")

proc customRule*(field: string,
    cb: proc(value: string, fields: TableRef[string, string]): bool {.closure.},
    message = ""): ValidationRule =
  ValidationRule(field: field, kind: vrCustom, custom: cb,
    message: if message.len > 0: message else: field & " is invalid")

proc getField(fields: TableRef[string, string], key: string): string =
  if not fields.isNil and fields.hasKey(key):
    fields[key]
  else:
    ""

proc validate*(fields: TableRef[string, string],
    rules: openArray[ValidationRule]): ValidationResult =
  ## Validates `fields` against `rules`. All rules run; every failure
  ## is collected in `errors`. `ok` is true when no errors occurred.
  result.values = fields
  result.errors = @[]
  for r in rules:
    let v = getField(fields, r.field)
    var passed = true
    case r.kind
    of vrRequired:
      passed = v.strip().len > 0
    of vrEmail:
      passed = v.len > 0 and isEmail(v)
    of vrMinLen:
      passed = v.len >= r.paramInt
    of vrMaxLen:
      passed = v.len <= r.paramInt
    of vrEqualsField:
      passed = v == getField(fields, r.paramStr)
    of vrStrongPassword:
      passed = isStrongPasswordStr(v)
    of vrNumeric:
      if v.len == 0: passed = false
      else:
        passed = true
        let start = if v[0] == '-': 1 else: 0
        if start >= v.len: passed = false
        else:
          for i in start ..< v.len:
            if v[i] notin {'0'..'9'}:
              passed = false
              break
    of vrInt:
      try:
        discard parseInt(v)
      except ValueError:
        passed = false
    of vrAlphaNum:
      passed = v.len > 0
      if passed:
        for c in v:
          if c notin {'a'..'z', 'A'..'Z', '0'..'9'}:
            passed = false
            break
    of vrSlug:
      passed = v.len > 0 and isSlug(v)
    of vrUuid:
      passed = v.len > 0 and isUUID(v)
    of vrCustom:
      if r.custom.isNil:
        passed = false
      else:
        try:
          passed = r.custom(v, fields)
        except CatchableError:
          passed = false
    if not passed:
      result.errors.add(ValidationError(
        field: r.field, rule: r.kind, message: r.message))
  result.ok = result.errors.len == 0

proc validate*(fields: openArray[(string, string)],
    rules: openArray[ValidationRule]): ValidationResult =
  ## Convenience overload for `seq[(key, value)]` (e.g. `getFields` output).
  var t = newTable[string, string]()
  for (k, v) in fields:
    t[k] = v
  validate(t, rules)

proc failedFields*(res: ValidationResult): seq[string] =
  ## Returns the distinct field names that failed validation.
  for e in res.errors:
    if e.field notin result:
      result.add(e.field)

proc errorFor*(res: ValidationResult, field: string): Option[string] =
  ## Returns the first error message for `field`, if any.
  for e in res.errors:
    if e.field == field:
      return some(e.message)

template withValidation*(fields: TableRef[string, string],
    rules: openArray[ValidationRule], onSuccess, onFailure: untyped) =
  ## Runs `onSuccess` when validation passes, otherwise `onFailure`
  ## with `validation: ValidationResult` in scope.
  block:
    let validation {.inject.} = validate(fields, rules)
    if validation.ok:
      onSuccess
    else:
      onFailure
