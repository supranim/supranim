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

## High-level HTTP client facade for Supranim, built on powpow's internal
## HTTP client (`HttpClient` / `AsyncHttpClient`, re-exported from
## `./httpclient`). Provides a simple fluent API for making requests:
## synchronous and asynchronous `get` / `post` (with `HttpForm` encoded as
## JSON), JSON deserialization via `get[T]`, per-request headers
## (`withHeaders`), bearer tokens (`withToken`), and automatic retries with a
## configurable backoff (`retry`). Also includes the `normalizePath` utility
## used by the web server backends to collapse repeated slashes.

import std/[uri, httpcore, asyncdispatch]
import pkg/openparser/json

import ./httpclient
export httpclient

type
  RetryAttemptCallback* = proc(): uint

  HttpForm* = openArray[tuple[key, val: string]]

  Http* = ref object
    httpClient: HttpClient
    retries: uint
    retryAttemptCallback: RetryAttemptCallback

  HttpResponse* = object
    res: HttpClientResponse

  AsyncHttp* = ref object
    httpClient: AsyncHttpClient
    retries: uint
    retryAttemptCallback: RetryAttemptCallback

proc body*(res: HttpResponse): string =
  ## Returns the response body as a string.
  res.res.getBodyString()

proc code*(res: HttpResponse): HttpCode =
  ## Returns the response status code.
  res.res.getStatusCode()

proc status*(res: HttpResponse): string =
  ## Returns the response status text.
  $res.res.getStatusText()

proc httpFormToJson(form: HttpForm): string =
  ## Serializes an `HttpForm` (a seq of key/value pairs) as a JSON object.
  var j = newJObject()
  for (k, v) in form:
    j[k] = %v
  $j

#
# GET handlers
#
proc get*(H: typedesc[Http], uri: Uri|string): HttpResponse =
  ## Sends a GET request to the specified URI and returns the response.
  var client = H(httpClient: newHttpClient())
  defer:
    client.httpClient.close()
  result = HttpResponse(res: client.httpClient.get($uri))

proc get*(H: Http, uri: Uri|string): HttpResponse =
  ## Sends a GET request to the specified URI and returns the response.
  defer:
    H.httpClient.close()
  result = HttpResponse(res: H.httpClient.get($uri))

proc get*[T](H: Http, uri: Uri|string, t: typedesc[T]): T =
  ## Sends a GET request to the specified URI and returns the
  ## response deserialized into the specified `T` type.
  let res = H.httpClient.get($uri)
  defer:
    H.httpClient.close()
  result = json.fromJson(res.getBodyString(), t)

#
# POST handlers
#
proc post*(H: typedesc[Http], uri: Uri|string, body: string = ""): HttpResponse =
  ## Sends a POST request to the specified URI with the given body
  ## and returns the response.
  var client = H(httpClient: newHttpClient())
  defer:
    client.httpClient.close()
  result = HttpResponse(res: client.httpClient.post($uri, body))

proc post*(H: typedesc[Http], uri: Uri|string, httpForm: HttpForm): HttpResponse =
  ## Sends a POST request to the specified URI with the given body
  ## and returns the response.
  var client = H(httpClient: newHttpClient())
  defer:
    client.httpClient.close()
  result = HttpResponse(res: client.httpClient.post($uri, httpFormToJson(httpForm)))

#
# Headers utils
#
proc withHeaders*(H: typedesc[Http],
    httpHeaders: openArray[tuple[key, val: string]]): Http =
  ## Instantiates a new Http object with the specified headers.
  result = H(httpClient: newHttpClient())
  result.httpClient.defaultHeaders = @httpHeaders

proc withToken*(H: Http, token: string): Http =
  ## Quickly adds a token to the request's Authorization header
  H.httpClient.defaultHeaders.add(("Authorization", "Bearer " & token))
  result = H

proc retry*(H: Http, times: uint): Http =
  ## Quickly adds a retry to the request
  H.retries = times
  result = H

proc retry*(H: Http, times: uint, retryAttemptCallback: RetryAttemptCallback): Http =
  ## Manually calculate the number of milliseconds to sleep between attempts,
  ## you may pass a closure as the second argument to the retry method.
  H.retries = times
  H.retryAttemptCallback = retryAttemptCallback
  result = H

#
# Async client
#
proc request(H: AsyncHttp, uri: Uri|string,
             httpMethod: HttpMethod, body = ""): Future[HttpClientResponse] {.async.} =
  ## Sends a request, retrying up to `H.retries` times on transient errors.
  ## When `H.retryAttemptCallback` is set it provides the delay in milliseconds
  ## between attempts (default 100ms).
  if H.retries == 0:
    return await H.httpClient.request(httpMethod, $uri, body)
  var attempts: uint = 0
  while true:
    try:
      return await H.httpClient.request(httpMethod, $uri, body)
    except CatchableError:
      if attempts >= H.retries:
        raise
      inc attempts
      let delay =
        if H.retryAttemptCallback != nil:
          H.retryAttemptCallback()
        else:
          100
      await sleepAsync(int(delay))

proc get*(H: typedesc[AsyncHttp], uri: Uri|string): Future[HttpClientResponse] {.async.} =
  ## Sends an async GET request to the specified URI and returns the response.
  var client = AsyncHttp(httpClient: newAsyncHttpClient())
  defer:
    client.httpClient.close()
  result = await client.request(uri, HttpGet)

proc get*(H: AsyncHttp, uri: Uri|string): Future[HttpClientResponse] {.async.} =
  ## Sends an async GET request to the specified URI and returns the response.
  defer:
    H.httpClient.close()
  result = await H.request(uri, HttpGet)

proc get*[T](H: AsyncHttp, uri: Uri|string, t: typedesc[T]): Future[T] {.async.} =
  ## Sends an async GET request to the specified URI and returns the
  ## response deserialized into the specified `T` type.
  let res = await H.request(uri, HttpGet)
  defer:
    H.httpClient.close()
  result = json.fromJson(res.getBodyString(), t)

proc post*(H: typedesc[AsyncHttp], uri: Uri|string,
           body: string = ""): Future[HttpClientResponse] {.async.} =
  ## Sends an async POST request to the specified URI with the given body
  ## and returns the response.
  var client = AsyncHttp(httpClient: newAsyncHttpClient())
  defer:
    client.httpClient.close()
  result = await client.request(uri, HttpPost, body)

proc post*(H: typedesc[AsyncHttp], uri: Uri|string,
           httpForm: HttpForm): Future[HttpClientResponse] =
  ## Sends an async POST request to the specified URI with a JSON-encoded
  ## form body and returns the response.
  ##
  ## The form is serialized before entering the async state machine (an
  ## `openArray` cannot be captured by an async closure).
  let body = httpFormToJson(httpForm)
  proc impl(): Future[HttpClientResponse] {.async.} =
    var client = AsyncHttp(httpClient: newAsyncHttpClient())
    defer:
      client.httpClient.close()
    result = await client.request(uri, HttpPost, body)
  impl()

proc withHeaders*(H: typedesc[AsyncHttp],
    httpHeaders: openArray[tuple[key, val: string]]): AsyncHttp =
  ## Instantiates a new AsyncHttp object with the specified headers.
  result = AsyncHttp(httpClient: newAsyncHttpClient())
  result.httpClient.defaultHeaders = @httpHeaders

proc withToken*(H: AsyncHttp, token: string): AsyncHttp =
  ## Quickly adds a token to the request's Authorization header
  H.httpClient.defaultHeaders.add(("Authorization", "Bearer " & token))
  result = H

proc retry*(H: AsyncHttp, times: uint): AsyncHttp =
  ## Quickly adds a retry to the async request
  H.retries = times
  result = H

proc retry*(H: AsyncHttp, times: uint,
            retryAttemptCallback: RetryAttemptCallback): AsyncHttp =
  ## Manually calculate the number of milliseconds to sleep between attempts,
  ## you may pass a closure as the second argument to the retry method.
  H.retries = times
  H.retryAttemptCallback = retryAttemptCallback
  result = H

proc normalizePath*(path: string): string =
  ## Collapses multiple slashes into one, e.g. //foo//bar -> /foo/bar
  result = ""
  var lastWasSlash = false
  for c in path:
    if c == '/':
      if not lastWasSlash:
        result.add(c)
      lastWasSlash = true
    else:
      result.add(c)
      lastWasSlash = false

when isMainModule:
  echo Http.get("https://example.com").body
