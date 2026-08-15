#
# Supranim is a high-performance web framework for building
# web applications and microservices in Nim
# 
#   (c) 2026 LGPL-v3-or-later License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#
import supranim/microservice

initService DataStore[UnixDomain]:
  description = "A HTTP-based Service Provider for magaging data storage and retrieval."
  autoStart = false
  # config = %*{
  #   "autoStart": false
  # }
  routes do:
    get "/datastore/ping":
      ## Health check endpoint for DataStore service
      req.respond(200, "DataStore Service is alive and well!")

    