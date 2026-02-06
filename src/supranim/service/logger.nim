# Supranim - A fast MVC web framework
# for building web apps & microservices in Nim.
#
#   (c) 2025 MIT License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim

import pkg/supranim/core/servicemanager

initService Logger[Global]:
  ## A thread-based web-service for handling
  ## logging in the web application.
  backend do:
    import std/[logging, os]
    import pkg/supranim/core/paths
    var httpErrorsFile = open(logsPath / "http.errors.log", fmWrite)
    var httpLogger*: FileLogger = newFileLogger(httpErrorsFile)
