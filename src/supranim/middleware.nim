# Supranim is a simple MVC-style web framework for building
# fast web applications, REST API microservices and other cool things.
#
# (c) 2021 Supranim is released under MIT License
#          George Lemon | Made by Humans from OpenPeep
#          https://supranim.com   |    https://github.com/supranim
import std/macros
from ./core/http/server import newRedirect, getRedirect
from ./core/http/response import redirects, abort
from ./core/http/router/router import Middleware, Response

export abort, redirects, newRedirect, getRedirect
export Middleware, Response