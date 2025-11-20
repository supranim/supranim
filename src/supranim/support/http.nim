# Supranim is a lightweight, high-performance MVC framework for Nim,
# designed to simplify the development of web applications and REST APIs.
#
# It features intuitive routing, modular architecture, and built-in support
# for modern web standards, making it easy to build scalable and maintainable
# projects.
#
# (c) 2025 Supranim | MIT License
#     Made by Humans from OpenPeeps
#     https://supranim.com | https://github.com/supranim

import std/[uri, httpcore, sequtils]
import pkg/jsony

import ../core/http/httpclient
export body

type
  RetryAttemptCallback* = proc(): uint

  HttpForm* = openArray[tuple[key, val: string]]

  Http* = ref object
    httpClient: HttpClient
    retries: uint
    retryAttemptCallback: RetryAttemptCallback

  HttpResponse* = object
    res: Response

  # AsyncHttp* = AsyncHttpClient
  # AsyncHttpFacade* = typedesc[AsyncHttp]

proc get*(H: typedesc[Http], uri: Uri|string): Response =
  ## Sends a GET request to the specified URI and returns the
  ## response body as a string.
  var client = H(httpClient: newHttpClient())
  defer:
    client.httpClient.close()
  result = client.httpClient.get(uri)

proc get*(H: Http, uri: Uri|string): Response =
  ## Sends a GET request to the specified URI and returns the
  ## response body as a string.
  defer:
    H.httpClient.close()
  result = H.httpClient.get(uri)

proc get*[T](H: Http, uri: Uri|string, t: typedesc[T]): T =
  ## Sends a GET request to the specified URI and returns the
  ## response deserialized into the specified `T` type.
  let res = H.httpClient.get(uri)
  defer:
    H.httpClient.close()
  let body = res.body
  result = jsony.fromJson(body, t)

#
# POST handlers
#
proc post*(H: typedesc[Http], uri: Uri|string, body: string = ""): Response =
  ## Sends a POST request to the specified URI with the given body
  ## and returns the response.
  var client = H(httpClient: newHttpClient())
  defer:
    client.httpClient.close()
  result = client.httpClient.post(uri)

proc post*(H: typedesc[Http], uri: Uri|string, httpForm:  HttpForm): Response =
  ## Sends a POST request to the specified URI with the given body
  ## and returns the response.
  var client = H(httpClient: newHttpClient())
  defer:
    client.httpClient.close()
  result = client.httpClient.post(uri, body = toJson(httpForm.toSeq()))

#
# Headers utils
#
proc withHeaders*(H: typedesc[Http],
    httpHeaders: openArray[tuple[key, val: string]]): Http =
  ## Instantiates a new Http object with the specified headers.
  result = H(
    httpClient: newHttpClient(
      headers = newHttpHeaders(httpHeaders)
    )
  )

proc withToken*(H: Http, token: string): Http =
  ## Quickly adds a token to the request's Authorization header
  if H.httpClient.headers == nil: H.httpClient.headers = newHttpHeaders()
  H.httpClient.headers.add("Authorization", "Bearer " & token)
  result = H

proc retry*(H: Http, times: uint): Http =
  ## Quickly adds a retry to the request
  H.retries = times

proc retry*(H: Http, times: uint, retryAttemptCallback: RetryAttemptCallback)  =
  ## Manually calculate the number of milliseconds to sleep between attempts,
  ## you may pass a closure as the second argument to the retry method.
  H.retryAttemptCallback = retryAttemptCallback


when isMainModule:
  # https://laravel.com/docs/12.x/http-client#events
  echo Http.get("https://example.com")