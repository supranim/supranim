#
# Supranim is a high-performance web framework for building
# web applications and microservices in Nim
#
#   (c) 2026 LGPL-v3-or-later License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#

## Minimal HTML view helpers for Supranim core (no extra dependencies).
##
## Full applications should use the Tim engine via the starter template
## (`src/service/provider/tim.nim`: layouts, partials, `render(view,
## layout, local)`). This module covers what core needs without it:
## error pages, small HTML responses, and `{{key}}` interpolation for
## string templates.
##
## Syntax for `renderTemplate`:
##
## - `{{key}}` → HTML-escaped value, unknown keys become `""`.
## - `{{{key}}}` → raw (unescaped) value, unknown keys become `""`.
## - Anything else (including a lone `{` or unclosed `{{`) is literal.
##
## .. code-block:: nim
##   import supranim/support/view
##
##   respondPage("Hello", "<p>Hi " & escapeHtml(name) & "</p>")
##   # or composed manually:
##   respond(Http200, layout("Hello", renderTemplate("Hi {{name}}!", vars)))

import std/[tables, strutils]
from std/httpcore import HttpCode, Http200

import ../core/response

proc escapeHtml*(s: string): string =
  ## Escapes `&<>"'` for safe interpolation into HTML.
  result = newStringOfCap(s.len + 16)
  for c in s:
    case c
    of '&': result.add("&amp;")
    of '<': result.add("&lt;")
    of '>': result.add("&gt;")
    of '"': result.add("&quot;")
    of '\'': result.add("&#39;")
    else: result.add(c)

proc renderTemplate*(tmpl: string, vars: TableRef[string, string]): string =
  ## Interpolates `{{key}}` (escaped) and `{{{key}}}` (raw).
  ## Unknown keys become `""`. Unclosed delimiters stay literal.
  result = newStringOfCap(tmpl.len + 32)
  var i = 0
  while i < tmpl.len:
    if tmpl[i] == '{' and i + 1 < tmpl.len and tmpl[i + 1] == '{':
      let rawOpen = i + 2 < tmpl.len and tmpl[i + 2] == '{'
      let openLen = if rawOpen: 3 else: 2
      let closeDelim = if rawOpen: "}}}" else: "}}"
      let closeIdx = tmpl.find(closeDelim, i + openLen)
      if closeIdx < 0:
        result.add(tmpl[i .. ^1])
        return
      let key = tmpl[i + openLen ..< closeIdx].strip()
      var val = ""
      if not vars.isNil and vars.hasKey(key):
        val = vars[key]
      if rawOpen:
        result.add(val)
      else:
        result.add(escapeHtml(val))
      i = closeIdx + closeDelim.len
    else:
      result.add(tmpl[i])
      inc i

proc renderTemplate*(tmpl: string,
    vars: openArray[(string, string)]): string =
  ## Convenience overload for inline `{"key": "value"}` pairs.
  var t = newTable[string, string]()
  for (k, v) in vars:
    t[k] = v
  renderTemplate(tmpl, t)

proc layout*(title, bodyHtml: string, headExtra = "",
    lang = "en"): string =
  ## Wraps `bodyHtml` in a minimal HTML5 document.
  ## `title` is escaped; `bodyHtml` and `headExtra` are trusted markup.
  "<!DOCTYPE html>\n<html lang=\"" & escapeHtml(lang) & "\">\n<head>\n" &
  "<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n" &
  "<title>" & escapeHtml(title) & "</title>\n" & headExtra &
  "\n</head>\n<body>\n" & bodyHtml & "\n</body>\n</html>"

proc renderPage*(title, bodyHtml: string, headExtra = ""): string =
  ## `layout` with the default document shell. Pure (no request needed).
  layout(title, bodyHtml, headExtra)

template respondPage*(title: string, bodyHtml: string,
    code: HttpCode = Http200, headExtra = "") {.dirty.} =
  ## Prepares an HTML page response (`text/html`) and blocks, mirroring
  ## the `json`/`respond` templates (handles `--app:lib` via `res[]`).
  ## Requires `req`/`res` in scope.
  when compileOption("app", "lib"):
    res[].setCode(code)
    res[].addHeader("Content-Type", "text/html; charset=utf-8")
    res[].setBody(layout(title, bodyHtml, headExtra))
  else:
    res.setCode(code)
    res.addHeader("Content-Type", "text/html; charset=utf-8")
    res.setBody(layout(title, bodyHtml, headExtra))
  return
