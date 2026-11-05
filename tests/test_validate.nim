#
# Unit tests for supranim/support/validate
#
import std/unittest
import std/[tables, options, strutils]

import supranim/support/validate

suite "support/validate":
  test "required fails on missing/blank":
    var fields = {"name": "  "}.newTable
    let r = validate(fields, [required("name")])
    check not r.ok
    check r.failedFields() == @["name"]
    check r.errorFor("name").isSome

  test "email validation":
    var okFields = {"email": "user@example.com"}.newTable
    check validate(okFields, [email("email")]).ok
    var badFields = {"email": "not-an-email"}.newTable
    let r = validate(badFields, [email("email")])
    check not r.ok
    check r.errorFor("email").get().contains("valid email")

  test "minLen / maxLen":
    var fields = {"pw": "short"}.newTable
    check not validate(fields, [minLen("pw", 8)]).ok
    check validate({"pw": "longenough"}.newTable, [minLen("pw", 8)]).ok
    check not validate({"pw": "toolongvalue"}.newTable, [maxLen("pw", 4)]).ok

  test "equalsField":
    var fields = {"pw": "secret123", "pw2": "secret123"}.newTable
    check validate(fields, [equalsField("pw2", "pw")]).ok
    fields["pw2"] = "different"
    check not validate(fields, [equalsField("pw2", "pw")]).ok

  test "strongPassword":
    check isStrongPasswordStr("Secret123")
    check not isStrongPasswordStr("weak")
    check not isStrongPasswordStr("alllowercase1")
    check not isStrongPasswordStr("ALLUPPERCASE1")
    check not isStrongPasswordStr("NoDigitsHere")
    var fields = {"pw": "Secret123"}.newTable
    check validate(fields, [strongPassword("pw")]).ok

  test "numeric / int / alphaNum / slug / uuid":
    check validate({"n": "12345"}.newTable, [numeric("n")]).ok
    check not validate({"n": "12a45"}.newTable, [numeric("n")]).ok
    check validate({"n": "-42"}.newTable, [numeric("n")]).ok
    check validate({"s": "my-blog-post"}.newTable, [slugRule("s")]).ok
    check not validate({"s": "Not A Slug!"}.newTable, [slugRule("s")]).ok
    check validate({"u": "550e8400-e29b-41d4-a716-446655440000"}.newTable, [uuidRule("u")]).ok
    check not validate({"u": "nope"}.newTable, [uuidRule("u")]).ok

  test "custom rule and seq overload":
    let fields = @[("age", "21")]
    let r = validate(fields, [customRule("age",
      proc(v: string, all: TableRef[string, string]): bool = v == "21")])
    check r.ok
    let r2 = validate(fields, [customRule("age",
      proc(v: string, all: TableRef[string, string]): bool = false,
      "must be 21")])
    check not r2.ok
    check r2.errorFor("age") == some("must be 21")

  test "withValidation template":
    var fields = {"email": "user@example.com"}.newTable
    withValidation(fields, [email("email")]):
      check validation.ok
    do:
      check false
