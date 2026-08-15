#
# Unit tests for supranim/support/slug
#
import std/unittest

import supranim/support/slug

suite "Slugify":
  test "converts whitespace to the separator":
    check slugify("Hello World") == "hello-world"
    check slugify("  leading and trailing  ") == "leading-and-trailing"

  test "collapses punctuation to the separator":
    check slugify("Hello, World!") == "hello-world"
    check slugify("Hello---World") == "hello-world"
    check slugify("Hello.World") == "hello-world"

  test "strips leading and trailing separators":
    check slugify("trailing---") == "trailing"
    check slugify("---leading") == "leading"

  test "lowercases output":
    check slugify("UPPER CASE") == "upper-case"

  test "transliterates unicode to ascii":
    check slugify("Café Mocha") == "cafe-mocha"

  test "custom separator":
    check slugify("Hello World", sep = '_') == "hello_world"

  test "allowSlash preserves slashes":
    check slugify("a/b/c") == "a-b-c"
    check slugify("a/b/c", allowSlash = true) == "a/b/c"

  test "generate is an alias of slugify":
    check generate("Another Example") == slugify("Another Example")
