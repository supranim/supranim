#
# Unit tests for supranim/support/logit
#
import std/unittest
import std/[os, strutils, times]

import supranim/support/logit

proc setupLogDir(): string =
  result = getTempDir() / "supranim_logit_test_" & $(getCurrentProcessId())
  createDir(result)

suite "Logit":
  test "initLogit raises IOError for a missing folder":
    expect IOError:
      discard initLogit("/nonexistent/supranim/logit")

  test "LogLevel $":
    check $LogLevel.TRACE == "TRACE"
    check $LogLevel.INFO == "INFO"
    check $LogLevel.ERROR == "ERROR"

  test "logs to a file":
    let dir = setupLogDir()
    defer: removeDir(dir)
    var logger = initLogit(dir, "Test", logToFile = true, logToConsole = false)
    logger.start()
    logger.info("hello logit")
    logger.finish()
    let filename = now().format("yyyy-MM-dd") & "_Test.log"
    let content = readFile(dir / filename)
    check "hello logit" in content
    check "INFO" in content

  test "log writes multiple entries":
    let dir = setupLogDir()
    defer: removeDir(dir)
    var logger = initLogit(dir, "Test", logToFile = true, logToConsole = false)
    logger.start()
    logger.warn("first warning")
    logger.error("second error")
    logger.finish()
    let filename = now().format("yyyy-MM-dd") & "_Test.log"
    let content = readFile(dir / filename)
    check "first warning" in content
    check "second error" in content
