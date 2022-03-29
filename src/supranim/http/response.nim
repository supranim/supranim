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

proc send(req: Request, code: HttpCode, body: string, headers="") =
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
    send(req, code, $code)

proc response*[R: Response](res: R, body: string, code = Http200) {.inline.} =
    ## Sends a HTTP 200 OK response with the specified body.
    ## **Warning:** This can only be called once in the OnRequest callback.
    res.req.send(code, body, headers = "")

proc send404*[R: Response](res: R, msg="404 | Not Found") {.inline.} =
    ## Sends a 404 HTTP Response with a default "404 | Not Found" message
    res.response(msg, Http404)

proc send500*[R: Response](res: R, msg="500 | Internal Error") {.inline.} =
    ## Sends a 500 HTTP Response with a default "500 | Internal Error" message
    res.response(msg, Http500)

template view*[R: Response](res: R, key: string, code = Http200) =
    res.response(getViewContent(App, key))

#
# JSON Responses
#
template json*[R: Response](res: R, jbody: untyped, code = Http200) =
    ## Sends a JSON Response with a default 200 (OK) status code
    res.req.send(code, toJson(jbody), "Content-Type: application/json")

template json404*[R: Response](res: R, body = "") =
    ## Sends a 404 JSON Response  with a default "Not found" message
    var jbody = if body.len == 0: """{"status": 404, "message": "Not Found"}""" else: body
    res.json(jbody, Http404)

template json500*[R: Response](res: R, body = "") =
    ## Sends a 500 JSON Response with a default "Internal Error" message
    var jbody = if body.len == 0: """{"status": 500, "message": "Internal Error"}""" else: body
    res.json(req, jbody, Http500)

#
# HTTP Redirects procedures
#
proc redirect*[R: Response](res: R, target:string, code = Http301) {.inline.} =
    ## Set a HTTP Redirect with a default 301 (Temporary) status code
    res.req.send(code, "", "Location: "&target)

proc redirect302*[R: Response](res: R, target:string) {.inline.} =
    ## Set a HTTP Redirect with `302` (Permanent) status code
    res.req.send(Http302, "", "Location: "&target)
