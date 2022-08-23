# Supranim is a simple MVC-style web framework for building
# fast web applications, REST API microservices and other cool things.
#
# (c) 2021 Supranim is released under MIT License
#          George Lemon | Made by Humans from OpenPeep
#          https://supranim.com   |    https://github.com/supranim
import std/macros

from ./core/http/server import newDeferredRedirect, getDeferredRedirect
from ./controller import redirects, abort
from ./core/http/router import Middleware, Response

export abort, redirects, newDeferredRedirect, getDeferredRedirect
export Middleware, Response