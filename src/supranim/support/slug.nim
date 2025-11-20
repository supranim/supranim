import std/[unidecode, strutils]

proc slugify*(str: string, sep: static char = '-'): string =
  ## Convert `input` string to a ascii slug
  var x = unidecode(str.strip())
  result = newStringOfCap(x.len)
  var i = 0
  while i < x.len:
    case x[i]
    of Whitespace:
      inc i
      try:
        while x[i] notin IdentChars:
          inc i
        add result, sep
      except IndexDefect: discard
    of PunctuationChars:
      inc i
      try:
        while x[i] notin IdentChars:
          inc i
        add result, sep
      except IndexDefect:
        discard
    else:
      add result, x[i].toLowerAscii
      inc i

proc generate*(str: string, sep: static char = '-'): string {.inline.} =
  ## An alias of `slugify`
  slugify(str, sep)