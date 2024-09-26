import std/[unidecode, strutils]

proc slugify*(str: string, sep: static char = '-'): string =
  ## Convert `input` string to a ascii slug
  var str = unidecode(str.strip)
  result = newStringOfCap(str.len)
  var i = 0
  while i < str.len:    
    case str[i]
    of Whitespace:
      inc i
      try:
        while str[i] notin IdentChars:
          inc i
        add result, sep
      except IndexDefect: discard
    of PunctuationChars:
      inc i
      try:
        while str[i] notin IdentChars:
          inc i
        add result, sep
      except IndexDefect:
        discard
    else:
      add result, str[i].toLowerAscii
      inc i