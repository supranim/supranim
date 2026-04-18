#
# Supranim is a high-performance web framework for building
# web applications and microservices in Nim
# 
#   (c) 2026 LGPL-v3-or-later License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#
import std/[os, options]
import pkg/supranim/core/[services, application, paths]
import pkg/supranim/support/logit
export logit

initService Logger[Singleton]:
  backend do:
      type Logger = ref object
        log: Logit
  
  client do:

    proc getLogger*(): ptr Logger =
      ## Returns the Singleton instance of the Logger service
      getLoggerInstance(
        proc(instance: ptr Logger) =
          {.gcsafe.}:
            let appLogsPath = App.paths.resolve("logs")
            discard existsOrCreateDir(appLogsPath)

            new(instance[])
            instance[].log =
              initLogit(appLogsPath, "Application",
                logToFile = true,
                logToConsole = true,
                exitOnError = false
              )
      )

    proc init*() =
      ## Initializes the Logger service by creating the logs directory if it doesn't exist
      getLogger().log.start()
    
    template logger*(message: string, level: LogLevel = INFO) =
      ## Logs a message using the Logger service. The `message` can be a string
      ## or any expression that evaluates to a string. The `level` specifies
      ## the log level (e.g., INFO, ERROR), and `autoNewLine` determines
      ## whether to automatically add a newline after the message
      let info = instantiationInfo()
      when not defined(supranimDisableLogging):
        log(getLogger().log, level, message, someInfo = some(info))