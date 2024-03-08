# Supranim is a simple MVC web framework
# for building web apps & microservices in Nim.
#
# (c) 2024 MIT License | Made by Humans from OpenPeeps
# https://supranim.com | https://github.com/supranim

import kapsis/commands
import supranim/cli/commands/[newCommand, serveCommand,
  stopCommand, listCommand]

App:
  about:
    "Manage Supranim applications via Supra interface"
    "  (c) Supranim / OpenPeeps - MIT License"
    "  https://supranim.com/docs/supra"
    "  https://github.com/supranim"
  
  commands:
    --- "New project"
    $ "new" ("web", "api"):
      ?       "Bootstrap a new Supranim application"
      ? app   "Create a new web app"
      ? rest  "Create a new REST API microservice"
    
    --- "App State"
    $ "serve" `app`:
      ? "Start application"
    $ "stop" `app`:
      ? "Stop application"

