import std/[macros, tables, nre,
  strutils, parseutils, sequtils,
  enumutils]

from std/httpcore import HttpMethod

type
  RoutePattern* = tuple[
    key: string,
    reKey: string,
    isOptional: bool
      # when prefixed with `?` char
      # will mark the pattern as optional
  ]
  Autolinked* = tuple[handleName, regexPath, path: string]
  RoutePatternsTable* = OrderedTableRef[string, RoutePattern]

const
  RegexPatterns = {
    "slug": "[0-9A-Za-z-_]+",
    "alphaSlug": "[A-Za-z-_]+",
    "id": "[0-9]+"
  }.toTable()

proc autolinkController*(routePath: string,
    httpMethod: HttpMethod, isWebSocket = false
): Autolinked {.compileTime.} =
  # Generates controller name and route
  # patterns from `routePath` string
  var
    i = 0
    patterns: OrderedTable[string, RoutePattern]
  while i < routePath.len:
    case routePath[i]
    of '{':
      # parse a named regex pattern
      inc(i) # skip {
      var p: RoutePattern
      i += routePath.parseUntil(p.key, {':'}, i)
      if i >= routePath.len:
        error("Invalid pattern missing ending `}`")
      else:
        inc(i) # skip :
        i += routePath.parseUntil(p.reKey, {'}', '?'}, i)
        p.isOptional = routePath[i] == '?'
        if p.isOptional:
          if likely(routePath[i+1] == '}'):
            inc(i, 2) # ?
          else:
            error("Invalid optional pattern missing ending `}`")
        else: inc(i) # }
        if likely(RegexPatterns.hasKey(p.reKey)):
          if likely(not patterns.hasKey(p.key)):
            patterns[p.key] = p
        else:
          let choices = RegexPatterns.keys.toSeq().join(", ")
          error("Unknown pattern `" & p.reKey &
            "`. Use one of: " & choices)
    else:
      var p: RoutePattern
      i += routePath.parseUntil(p.key, {'{'}, i)
      patterns[p.key] = p
  let methodName =
    if isWebSocket: "ws" # websocket handles are always prefixed with `ws`
    else: toLowerAscii(symbolName(httpMethod)[4..^1])
  var
    pathRegExpr: string
    ctrlName = methodName
  for x, v in patterns:
    if v.reKey.len > 0:
      add pathRegExpr,
        if not v.isOptional:
          "(?<" & x & ">" & RegexPatterns[v.reKey] & ")"
        else:
          "(?<" & x & ">(" & RegexPatterns[v.reKey] & ")?)"
      add ctrlName, capitalizeAscii(x)
    else:
      var i = 0
      var needsUpper: bool
      var prepareCtrlName: string
      while i < x.len:
        case x[i]
        of {'-', '_'}:
          needsUpper = true; inc(i)
        of '/':
          needsUpper = true; inc(i);
        else:
          if needsUpper:
            add prepareCtrlName, x[i].toUpperAscii()
            needsUpper = false
          else:
            add prepareCtrlName, x[i]
          inc(i)
      add ctrlName, prepareCtrlName.capitalizeAscii()
      add pathRegExpr,
        strutils.multiReplace(x,
          ("/", "\\/"), ("-", "\\-"), ("+", "\\+")
        )
  add pathRegExpr, "$"
  if ctrlName == methodName:
    add ctrlName, "Homepage"
  result = (ctrlName, pathRegExpr, routePath)
  when defined supranimDebugAutolink:
    debugEcho result

