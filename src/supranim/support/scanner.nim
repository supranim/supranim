#
# Supranim is a high-performance web framework for building
# web applications and microservices in Nim
# 
#   (c) 2026 LGPL-v3-or-later License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#

## This module provides a high-level text scanning utility built on top of the
## SIMD-optimized OpenParser Regex Engine. It allows you to define reusable scanners
## for common patterns (like emails, URLs, etc.), or custom patterns, and efficiently scan input
## strings for matches and capture groups.

import openparser/regex/vm
export vm.MatchResult, vm.CaptureGroup

#
# Common Web App Regex Patterns
#
const
  # Identity & Auth
  PatternEmail*        = r"[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}"
  PatternUsername*     = r"[a-zA-Z][a-zA-Z0-9_\-]{2,31}"
  PatternPassword*     = r"[^\s]{8,128}"
  PatternUUID*         = r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
  PatternSlug*         = r"[a-z0-9]+(?:-[a-z0-9]+)*"
  PatternJWT*          = r"[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]+"

  # Network
  PatternIPv4*         = r"(?:(?:25[0-5]|2[0-4]\d|[01]?\d\d?)\.){3}(?:25[0-5]|2[0-4]\d|[01]?\d\d?)"
  PatternIPv6*         = r"(?:[0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}"
  PatternURL*          = r"https?://[^\s/$.?#].[^\s]*"
  PatternDomain*       = r"(?:[a-zA-Z0-9](?:[a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}"
  PatternPort*         = r"(?:6553[0-5]|655[0-2]\d|65[0-4]\d{2}|6[0-4]\d{3}|[1-5]\d{4}|[1-9]\d{0,3})"

  # Data Formats
  PatternDate*         = r"\d{4}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12]\d|3[01])"
  PatternTime*         = r"(?:[01]\d|2[0-3]):[0-5]\d(?::[0-5]\d)?"
  PatternDatetime*     = r"\d{4}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12]\d|3[01])T(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d"
  PatternHexColor*     = r"#(?:[0-9a-fA-F]{6}|[0-9a-fA-F]{3})"
  PatternJSON*         = r"\{[^{}]*\}"
  PatternSemVer*       = r"\d+\.\d+\.\d+(?:-[a-zA-Z0-9.]+)?"

  # Numbers & Finance
  PatternInteger*      = r"-?\d+"
  PatternFloat*        = r"-?\d+\.\d+"
  PatternCurrency*     = r"[$€£¥]\d+(?:,\d{3})*(?:\.\d{2})?"
  PatternCreditCard*   = r"(?:\d{4}[- ]){3}\d{4}"
  PatternIBAN*         = r"[A-Z]{2}\d{2}[A-Z0-9]{1,30}"

  # Phone
  PatternPhone*        = r"\+?[\d\s\-().]{7,20}"
  PatternE164*         = r"\+[1-9]\d{6,14}"

  # Content
  PatternHTMLTag*      = r"<[^>]+>"
  PatternMention*      = r"@[a-zA-Z0-9_]{1,50}"
  PatternHashtag*      = r"#[a-zA-Z0-9_]{1,50}"
  PatternMarkdownLink* = r"\[[^\]]+\]\([^)]+\)"

  # Paths & Files
  PatternUnixPath*     = r"/(?:[^\s/]+/)*[^\s/]*"
  PatternFileExt*      = r"\.[a-zA-Z0-9]{1,10}"
  PatternMimeType*     = r"[a-zA-Z]+/[a-zA-Z0-9\-+.]+"

  # Identifiers (useful for parsers)
  PatternIdent*        = r"[a-zA-Z_]\w*"
  PatternConstant*     = r"[A-Z_][A-Z0-9_]+"
  PatternEnvVar*       = r"\$\{?[A-Z_][A-Z0-9_]*\}?"

type
  Scanner* = object
    ## Reusable scanner. Compile a pattern once, match many inputs.
    vm: RegexVM

  ScanMatch* = MatchResult

#
# Scanner API
#

proc newScanner*(pattern: string): Scanner =
  ## Create a reusable scanner for a compiled pattern.
  Scanner(vm: initRegexVM(compile(pattern)))

proc scan*(s: var Scanner, input: string): ScanMatch {.inline.} =
  ## Anchored full match — input must match completely.
  s.vm.match(input)

proc scanFind*(s: var Scanner, input: string): ScanMatch {.inline.} =
  ## Find leftmost match anywhere in input.
  s.vm.find(input)

proc scanAll*(s: var Scanner, input: string): seq[ScanMatch] {.inline.} =
  ## Find all non-overlapping matches in input.
  s.vm.findAll(input)

proc matched*(m: ScanMatch): bool {.inline.} = m.matched
proc start*(m: ScanMatch): int {.inline.} = m.start
proc stop*(m: ScanMatch): int {.inline.} = m.stop

proc capture*(m: ScanMatch, input: string, idx: int = 0): string {.inline.} =
  ## Extract match or capture group. idx=0 → whole match.
  m.group(idx).str(input)

proc captures*(m: ScanMatch, input: string): seq[string] {.inline.} =
  ## All capture groups as strings (idx 1..n).
  m.groups(input)

#
# One-shot convenience procs per pattern
# Each proc creates a short-lived VM — prefer newScanner for repeated use.
#

template defScanProc(name, pattern: untyped) =
  proc name*(input: string): ScanMatch =
    var vm = initRegexVM(compile(pattern))
    vm.match(input)
  proc `name Find`*(input: string): ScanMatch =
    var vm = initRegexVM(compile(pattern))
    vm.find(input)
  proc `name All`*(input: string): seq[ScanMatch] =
    var vm = initRegexVM(compile(pattern))
    vm.findAll(input)

defScanProc(scanEmail,      PatternEmail)
defScanProc(scanUsername,   PatternUsername)
defScanProc(scanPassword,   PatternPassword)
defScanProc(scanUUID,       PatternUUID)
defScanProc(scanSlug,       PatternSlug)
defScanProc(scanJWT,        PatternJWT)
defScanProc(scanIPv4,       PatternIPv4)
defScanProc(scanIPv6,       PatternIPv6)
defScanProc(scanURL,        PatternURL)
defScanProc(scanDomain,     PatternDomain)
defScanProc(scanDate,       PatternDate)
defScanProc(scanTime,       PatternTime)
defScanProc(scanDatetime,   PatternDatetime)
defScanProc(scanHexColor,   PatternHexColor)
defScanProc(scanSemVer,     PatternSemVer)
defScanProc(scanInteger,    PatternInteger)
defScanProc(scanFloat,      PatternFloat)
defScanProc(scanPhone,      PatternPhone)
defScanProc(scanE164,       PatternE164)
defScanProc(scanHTMLTag,    PatternHTMLTag)
defScanProc(scanMention,    PatternMention)
defScanProc(scanHashtag,    PatternHashtag)
defScanProc(scanIdent,      PatternIdent)
defScanProc(scanConstant,   PatternConstant)
defScanProc(scanEnvVar,     PatternEnvVar)

#
# Validation helpers (bool return)
#
template defValidateProc(name, scanProc: untyped) =
  proc name*(input: string): bool {.inline.} =
    scanProc(input).matched

defValidateProc(isEmail,    scanEmail)
defValidateProc(isUsername, scanUsername)
defValidateProc(isUUID,     scanUUID)
defValidateProc(isSlug,     scanSlug)
defValidateProc(isIPv4,     scanIPv4)
defValidateProc(isURL,      scanURL)
defValidateProc(isDomain,   scanDomain)
defValidateProc(isDate,     scanDate)
defValidateProc(isTime,     scanTime)
defValidateProc(isHexColor, scanHexColor)
defValidateProc(isSemVer,   scanSemVer)
defValidateProc(isJWT,      scanJWT)
defValidateProc(isE164,     scanE164)

when isMainModule:
  # One-shot validation
  assert isEmail("user@example.com")
  assert isSlug("my-blog-post")

  # Full match vs find
  let m = scanUUID("550e8400-e29b-41d4-a716-446655440000")
  if m.matched:
    echo m.capture(input)   # whole match

  # Find all mentions in text
  let mentions = scanMentionAll("Hey @alice and @bob!")
  for m in mentions:
    echo m.capture("Hey @alice and @bob!")  # @alice, @bob

  # Reusable scanner (recommended for hot paths)
  var emailScanner = newScanner(PatternEmail)
  for line in lines:
    let m = emailScanner.scanFind(line)
    if m.matched: echo m.capture(line)