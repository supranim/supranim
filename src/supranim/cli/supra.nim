# Supranim is a simple MVC web framework
# for building web apps & microservices in Nim.
#
# (c) 2024 MIT License | Made by Humans from OpenPeeps
# https://supranim.com | https://github.com/supranim

import kapsis/app
import ./commands/[new, serve, stop, list]

commands:
  -- "New project"
  new [web, api]:
    ## Bootstrap a new Supranim application
    ? app   "Create a new web app"
    ? rest  "Create a new REST API microservice"
  
  -- "App State"
  serve `app`:
    ## start the application

  stop `app`:
    ## stop the application

