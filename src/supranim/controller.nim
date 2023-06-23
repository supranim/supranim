# Supranim is a simple MVC-style web framework for building
# fast web applications, REST API microservices and other cool things.
#
# (c) 2022 Supranim is released under MIT License
#          Made by Humans from OpenPeep
#          https://supranim.com | https://github.com/supranim

import pkg/[pkginfo, jsony]
import std/[options, sequtils, critbits, uri]

from ./support/str import unquote
from ./core/private/server import Request, requestBody,
                hasHeaders, hasHeader, getHeaders, getHeader,
                path, getCurrentPath, getVerb, HttpCode,
                getParams, hasParams, path, getRequestQuery,
                HttpResponse
from ./application import AppDirectory, path
export AppDirectory, path

import std/json
export `%*`

when requires "kashae":
  import kashae
  export kashae

export jsony, critbits
export Request, HttpResponse, hasHeaders, hasHeader, getHeaders, 
     getHeader, path, getCurrentPath, HttpCode,
     getParams, hasParams, path

#
# Request - Higher-level
#

proc getBody*(req: Request): string =
  ## Retrieve the body of given `Request`
  result = req.requestBody.get()

proc getFields*(req: Request): seq[(string, string)] =
  ## Decodes the query string from current `Request`
  result = toSeq(req.getBody().decodeQuery)

proc getQuery*(req: Request): CritBitTree[string] =
  ## Decodes the query string from current `Request` of `HttpGet`
  for q in decodeQuery(req.getRequestQuery):
    result[q.key] = q.value
  # result = toSeq(decodeQuery(req.getRequestQuery))

when defined webapp:
  ## Controller methods available for `webapp` projects *(gui apps)
  proc isPage*(req: Request, key: string): bool =
    ## Determine if current page is as expected
    result = req.getCurrentPath() == key

  proc getAgent*(req: Request): string =
    ## Retrieves the user agent from request header
    result = req.getHeader("user-agent")

  proc getPlatform*(req: Request): string =
    ## Return the platform name, It can be one of the following common platform values:
    ## ``Android``, ``Chrome OS``, ``iOS``, ``Linux``, ``macOS``, ``Windows``, or ``Unknown``.
    # https://wicg.github.io/ua-client-hints/#sec-ch-ua-platform
    result = unquote(req.getHeader("sec-ch-ua-platform"))

  proc isMacOS*(req: Request): bool =
    ## Determine if current request is made from ``macOS`` platform
    result = req.getPlatform() == "macOS"

  proc isLinux*(req: Request): bool =
    ## Determine if current request is made from ``Linux`` platform
    result = req.getPlatform() == "Linux"

  proc isWindows*(req: Request): bool =
    ## Determine if current request is made from ``Window`` platform
    result = req.getPlatform() == "Windows"

  proc isChromeOS*(req: Request): bool =
    ## Determine if current request is made from ``Chrome OS`` platform
    result = req.getPlatform() == "Chrome OS"

  proc isIOS*(req: Request): bool =
    ## Determine if current request is made from ``iOS`` platform
    result = req.getPlatform() == "iOS"

  proc isAndroid*(req: Request): bool =
    ## Determine if current request is made from ``Android`` platform
    result = req.getPlatform() == "Android"

  proc isMobile*(req: Request): bool =
    ## Determine if current request is made from a mobile device
    ## https://wicg.github.io/ua-client-hints/#sec-ch-ua-mobile
    result = req.getPlatform() in ["Android", "iOS"] and
         req.getHeader("sec-ch-ua-mobile") == "true"

#
# Response - Higher-level
#
from ./core/private/server import Response, response, send404, send500,
              addCacheControl, json, json404, json500,
              redirect, redirects, abort, newCookie, getDeferredRedirect,
              setSessionId, addCookieHeader

export addCookieHeader

when defined webapp:
  ## Export methods for `webapp` projects
  from ./core/private/server import view, css, js
  export view, css, js

  when requires "tim":
    template render*(view: string, layout = "base", data: untyped): untyped =
      res.response(Tim.render(view, layout, data))

    template render*(view: string, layout = "base", data: JsonNode): untyped =
      res.response(Tim.render(view, layout, data, %*{"isPage": "/" & req.getCurrentPath()}))

    template render*(view: string, layout = "base"): untyped =
      res.response(Tim.render(view, layout))

export Response, response, send404, send500,
    addCacheControl, server.json, json404, json500, redirect,
    redirects, abort, newCookie, getDeferredRedirect

proc send*(res: var Response, body: string, code = HttpCode(200), contentType = "text/html"): HttpResponse =
  response(res, body, code, contentType)