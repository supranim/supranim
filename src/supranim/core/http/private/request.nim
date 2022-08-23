# Supranim is a simple MVC-style web framework for building
# fast web applications, REST API microservices and other cool things.
#
# (c) 2022 Supranim is released under MIT License
#          Made by Humans from OpenPeep
#          https://supranim.com | https://github.com/supranim

# This is an include-only module

proc getRequest*(res: Response): Request =
    ## Returns the current Request instance
    result = res.req

#
# Response Handler
#
proc unsafeSend*(req: Request, data: string) =
    ## Sends the specified data on the request socket.
    ##
    ## This function can be called as many times as necessary.
    ##
    ## It does not check whether the socket is in
    ## a state that can be written so be careful when using it.
    if req.client notin req.selector: return
    withRequestData(req):
        requestData.sendQueue.add(data)
    req.selector.updateHandle(req.client, {selectors.Event.Read, selectors.Event.Write})

proc send*(req: Request, code: HttpCode, body: string, headers="") =
    ## Responds with the specified HttpCode and body.
    ## **Warning:** This can only be called once in the OnRequest callback.
    if req.client notin req.selector:
        return
    withRequestData(req):
        # assert requestData.headersFinished, "Selector not ready to send."
        # if requestData.requestID != req.requestID:
            # raise SupranimDefect(msg: "You are attempting to send data to a stale request.")
        let otherHeaders = if likely(headers.len == 0): "" else: "\c\L" & headers
        var
            text = (
                "HTTP/1.1 $#\c\L" &
                "Content-Length: $#\c\LDate: $#$#\c\L\c\L$#"
            ) % [$code, $body.len, serverDate, otherHeaders, body]

        requestData.sendQueue.add(text)
    req.selector.updateHandle(req.client, {selectors.Event.Read, selectors.Event.Write})

proc send*(req: Request, code: HttpCode) =
    ## Responds with the specified HttpCode. The body of the response
    ## is the same as the HttpCode description.
    send(req, code, $code)

var requestCounter: uint = 0
proc genRequestID(): uint =
    if requestCounter == high(uint):
        requestCounter = 0
    requestCounter += 1
    return requestCounter

method validateRequest(req: Request): bool {.gcsafe.}

method getVerb*(req: Request): HttpMethod = 
    ## Retrieve the `HttpMethod` from given `Request`
    result = req.methodType

method hasHeaders*(req: Request): bool =
    ## Determine if current Request instance has any headers
    result = req.reqHeaders.get() != nil

proc hasHeaders*(headers: Option[HttpHeaders]): bool =
    ## Checks for existing headers for given `Option[HttpHeaders]`
    result = headers.get() != nil

method getHeaders*(req: Request): Option[HttpHeaders] =
    ## Returns all `HttpHeaders` from current `Request` instance
    result = req.reqHeaders

method hasHeader*(req: Request, key: string): bool =
    ## Determine if current Request instance has a specific header
    result = req.reqHeaders.get().hasKey(key)

proc hasHeader*(headers: Option[HttpHeaders], key: string): bool =
    ## Determine if current `Request` intance contains a specific header by `key`
    result = headers.get().hasKey(key)

method getHeader*(req: Request, key: string): string = 
    ## Retrieves a specific header from given `Option[HttpHeaders]`
    let headers = req.reqHeaders.get()
    if headers.hasKey(key):
        result = headers[key]

proc getHeader*(headers: Option[HttpHeaders], key: string): string = 
    ## Retrieves a specific header from given `Option[HttpHeaders]`
    if headers.hasHeader(key): result = headers.get()[key]

method httpMethod*(req: Request): Option[HttpMethod] =
    ## Parses the request's data to find the request HttpMethod.
    result = parseHttpMethod(req.selector.getData(req.client).data, req.start)

method path*(req: Request): Option[string] =
    ## Parses the request's data to find the request target.
    if unlikely(req.client notin req.selector): return
    result = parsePath(req.selector.getData(req.client).data, req.start)

method getCurrentPath*(req: Request): string = 
    ## Alias for retrieving the route path from current request
    result = req.path().get()
    if result[0] == '/':
        result = result[1 .. ^1]

proc getParams*(req: Request): seq[RoutePatternRequest] =
    ## Retrieve all URL parameters from current request.
    result = req.patterns

proc hasParams*(req: Request): bool =
    ## Determine if the current request contains
    ## any parameters from the dynamic route
    result = req.patterns.len != 0

proc setParams*(req: var Request, reqValues: seq[RoutePatternRequest]) =
    ## Map values from request to route parameters
    ## Add dynamic route values from current request 
    for reqVal in reqValues:
        req.patterns.add(reqVal)

method headers*(req: Request): Option[HttpHeaders] =
    ## Parses the request's data to get the headers.
    if unlikely(req.client notin req.selector):
        return
    parseHeaders(req.selector.getData(req.client).data, req.start)

method addHeader*(res: var Response, key, value: string) =
    ## Add a new Response Header to given instance.
    res.headers.add(key, value)

method getHeaders*(res: Response): string =
    ## Returns the stringified HTTP Headers of `Response` instance
    var hstr: seq[string]
    for h in res.headers.pairs():
        hstr.add(h.key & ":" & indent(h.value, 1))
    result &= hstr.join("\n")

method requestBody*(req: Request): Option[string] =
    ## Retrieves the body from current Request
    let pos = req.selector.getData(req.client).headersFinishPos
    if pos == -1: return none(string)
    result = req.selector.getData(req.client).data[pos .. ^1].some()

    when not defined(release):
        let length =
            if req.headers.get().hasKey("Content-Length"):
                req.headers.get()["Content-Length"].parseInt()
            else: 0
        assert result.get().len == length

# proc ip*(req: Request): string =
#     ## Retrieves the IP address from request
#     req.selector.getData(req.client).ip

method forget*(req: Request) =
    ## Unregisters the underlying request's client socket from event loop.
    ##
    ## This is useful when you want to register ``req.client`` in your own
    ## event loop, for example when wanting to integrate the server into a
    ## websocket library.
    assert req.selector.getData(req.client).requestID == req.requestID
    req.selector.unregister(req.client)

method validateRequest(req: Request): bool =
    ## Handles protocol-mandated responses.
    ##
    ## Returns ``false`` when the request has been handled.
    result = true

    # From RFC7231: "When a request method is received
    # that is unrecognized or not implemented by an origin server, the
    # origin server SHOULD respond with the 501 (Not Implemented) status
    # code."
    if req.httpMethod().isNone():
        req.send(Http501)
        return false
