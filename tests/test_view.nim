#
# Unit tests for supranim/support/view
#
import std/unittest
import std/[httpcore, tables, strutils]

import supranim/support/view
import supranim/core/request
import supranim/core/response

var gRes = new(Response)

proc applyPage() =
  var req = default(Request)
  gRes[] = Response(headers: newHttpHeaders())
  template res: var Response = gRes[]
  respondPage("Hello", "<p>body</p>")

suite "support/view":
  test "escapeHtml escapes markup chars":
    check escapeHtml("<a href=\"x\">&'") == "&lt;a href=&quot;x&quot;&gt;&amp;&#39;"

  test "renderTemplate interpolates escaped values":
    let s = renderTemplate("Hi {{name}}!", [("name", "<bob>")])
    check s == "Hi &lt;bob&gt;!"

  test "renderTemplate raw triple braces skip escaping":
    let s = renderTemplate("Hi {{{name}}}!", [("name", "<b>bob</b>")])
    check s == "Hi <b>bob</b>!"

  test "renderTemplate unknown keys become empty":
    check renderTemplate("a{{missing}}b", [("x", "y")]) == "ab"
    check renderTemplate("a{{{missing}}}b", [("x", "y")]) == "ab"

  test "renderTemplate leaves unclosed delimiters literal":
    check renderTemplate("a {{oops", [("oops", "x")]) == "a {{oops"
    check renderTemplate("a {b} c", [("b", "x")]) == "a {b} c"

  test "renderTemplate seq overload":
    check renderTemplate("{{a}}-{{b}}", @[("a", "1"), ("b", "2")]) == "1-2"

  test "renderTemplate TableRef overload":
    var vars = newTable[string, string]()
    vars["name"] = "<bob>"
    check renderTemplate("Hi {{name}}!", vars) == "Hi &lt;bob&gt;!"

  test "layout wraps a full HTML5 document":
    let doc = layout("T & C", "<p>hi</p>")
    check doc.startsWith("<!DOCTYPE html>")
    check "<title>T &amp; C</title>" in doc
    check "<p>hi</p>" in doc
    check "charset=\"utf-8\"" in doc

  test "respondPage sets html content type and body":
    applyPage()
    check gRes[].getCode == Http200
    check gRes[].getHeaders["Content-Type"] == "text/html; charset=utf-8"
    check "<title>Hello</title>" in gRes[].getBody
    check "<p>body</p>" in gRes[].getBody
