# Supranim is a simple Hyper Server and Web Framework developed
# for building safe & fast in-house projects.
# 
# Supranim - Response Handler
# This is an include-only file, part of the ./server.nim
# 
# (c) 2021 Supranim is released under MIT License
#          by George Lemon <georgelemon@protonmail.com>
#          
#          Website: https://supranim.com
#          Github Repository: https://github.com/supranim

var serverDate {.threadvar.}: string

proc updateDate(fd: AsyncFD): bool =
    result = false # Returning true signifies we want timer to stop.
    serverDate = now().utc().format("ddd, dd MMM yyyy HH:mm:ss 'GMT'")

template withRequestData(req: Request, body: untyped) =
    let requestData {.inject.} = addr req.selector.getData(req.client)
    body

#
# Response Handler
#
proc unsafeSend*(req: Request, data: string) {.inline.} =
    ## Sends the specified data on the request socket.
    ##
    ## This function can be called as many times as necessary.
    ##
    ## It does not check whether the socket is in
    ## a state that can be written so be careful when using it.
    if req.client notin req.selector:
        return
    withRequestData(req):
        requestData.sendQueue.add(data)
    req.selector.updateHandle(req.client, {Event.Read, Event.Write})

proc send*(req: Request, code: HttpCode, body: string, headers="") =
    ## Responds with the specified HttpCode and body.
    ## **Warning:** This can only be called once in the OnRequest callback.
    if req.client notin req.selector:
        return

    withRequestData(req):
        # assert requestData.headersFinished, "Selector not ready to send."
        if requestData.requestID != req.requestID:
            raise HttpBeastDefect(msg: "You are attempting to send data to a stale request.")

        let otherHeaders = if likely(headers.len == 0): "" else: "\c\L" & headers
        var
            text = (
                "HTTP/1.1 $#\c\L" &
                "Content-Length: $#\c\LServer: $#\c\LDate: $#$#\c\L\c\L$#"
            ) % [$code, $body.len, serverInfo, serverDate, otherHeaders, body]

        requestData.sendQueue.add(text)
    req.selector.updateHandle(req.client, {Event.Read, Event.Write})

#
# Http Responses
#
proc send*(req: Request, code: HttpCode) =
    ## Responds with the specified HttpCode. The body of the response
    ## is the same as the HttpCode description.
    req.send(code, $code)

proc send*(req: Request, body: string, code = Http200) {.inline.} =
    ## Sends a HTTP 200 OK response with the specified body.
    ## **Warning:** This can only be called once in the OnRequest callback.
    req.send(code, body)

proc send404*(req: Request, msg="404 | Not Found") {.inline.} =
    ## Sends a 404 HTTP Response with a default "404 | Not Found" message
    send(req, msg, Http404)

proc send500*(req: Request, msg="500 | Internal Error") {.inline.} =
    ## Sends a 500 HTTP Response with a default "500 | Internal Error" message
    send(req, msg, Http500)

#
# JSON Responses
#
proc sendJson*(req: Request, jbody: JsonNode, code = Http200) {.inline.} =
    ## Sends a Json Response with a default 200 (OK) status code
    req.send(code, $jbody, "Content-Type: application/json")

proc send404Json*(req: Request, msg: JsonNode = %*{"status": 404, "message": "Not Found"}) {.inline.} =
    ## Sends a 404 JSON Response  with a default "Not found" message
    sendJson(req, msg, Http404)

proc send500Json*(req: Request, msg: JsonNode = %*{"status": 500, "message": "Internal Error"}) {.inline.} =
    ## Sends a 500 JSON Response with a default "Internal Error" message
    sendJson(req, msg, Http500)

#
# HTTP Redirects procedures
#
proc redirect*(req: Request, target:string, code = Http301) {.inline.} =
    ## Set a HTTP Redirect with a default 301 (Temporary) status code
    req.send(code, "", "Location: "&target)

proc redirect302*(req: Request, target:string) {.inline.} =
    ## Set a HTTP Redirect with `302` (Permanent) status code
    req.send(Http301, "", "Location: "&target)
