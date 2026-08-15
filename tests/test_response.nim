#
# Unit tests for supranim/core/response
#
import std/unittest
import std/[httpcore, json, strutils]

import supranim/core/request
import supranim/core/response

var gRes = new(Response)

proc applyJson() =
  var req = default(Request)
  gRes[] = Response(headers: newHttpHeaders())
  template res: var Response = gRes[]
  json(%*{"a": 1})

proc applyRespond() =
  var req = default(Request)
  gRes[] = Response(headers: newHttpHeaders())
  template res: var Response = gRes[]
  respond("hello", "text/plain")

suite "Response":
  test "getContentType defaults to json":
    check getContentType() == "application/json; charset=utf-8"

  test "getDefault":
    check getDefault(Http403) == "Forbidden"
    check getDefault(Http404).len > 0
    check getDefault(Http500) == ""

  test "json template prepares a JSON response":
    applyJson()
    check gRes[].getCode == Http200
    check gRes[].getHeaders["Content-Type"] == "application/json; charset=utf-8"
    check gRes[].getBody == """{"a":1}"""

  test "respond template sets body and content type":
    applyRespond()
    check gRes[].getCode == Http200
    check gRes[].getHeaders["Content-Type"] == "text/plain"
    check gRes[].getBody == "hello"

  test "setCode/getCode and setBody/getBody":
    var res = Response(headers: newHttpHeaders())
    check res.getCode == Http200
    res.setCode(Http418)
    check res.getCode == Http418
    res.setBody("payload")
    check res.getBody == "payload"

  test "addHeader/getHeaders":
    var res = Response(headers: newHttpHeaders())
    res.addHeader("X-Custom", "value")
    check res.getHeaders["X-Custom"] == "value"

  test "toString formats headers as key: value lines":
    var headers = newHttpHeaders()
    headers.add("A", "1")
    headers.add("B", "2")
    let s = toString(headers)
    check "a: 1" in s
    check "b: 2" in s
