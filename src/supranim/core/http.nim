# Supranim is a simple MVC web framework
# for building web apps & microservices in Nim.
#
# (c) 2024 MIT License | Made by Humans from OpenPeeps
# https://supranim.com | https://github.com/supranim
import ./config

when supranimServer == "httpbeast":
  include pkg/httpbeast
  proc runServer*(onRequest: OnRequest, settings: Settings) =
    ## Starts the HTTP server
    if settings.numThreads > 1:
      when compileOption("threads"):
        var threads = newSeq[Thread[(OnRequest, Settings, bool)]](settings.numThreads - 1)
        for t in threads.mitems():
          createThread[(OnRequest, Settings, bool)](
            t, eventLoop, (onRequest, settings, false)
          )
        when NimMajor >= 2:
          addExitProc(proc() =
            for thr in threads:
              when compiles(pthread_cancel(thr.sys)):
                discard pthread_cancel(thr.sys)
              if not isNil(thr.core):
                when defined(gcDestructors):
                  c_free(thr.core)
                else:
                  deallocShared(thr.core)
          )
      else:
        assert false
    eventLoop((onRequest, settings, true))

  proc resp*(req: Request, code: HttpCode, body: sink string, headers="") =
    ## Responds with the specified HttpCode and body.
    ##
    ## **Warning:** To be called once in the OnRequest callback.
    if req.client notin req.selector:
      return
    withRequestData(req):
      assert requestData.headersFinished, "Selector for $1 not ready to send." % $req.client.int
      if requestData.requestID != req.requestID:
        # raise HttpBeastDefect(msg: "You are attempting to send data to a stale request.")
        req.selector.unregister(req.client)
        req.client.close()
        return

      let
        otherHeaders = if likely(headers.len == 0): "" else: "\c\L" & headers
        origLen = requestData.sendQueue.len
        # We estimate how long the data we are
        # adding will be. Keep this in mind
        # if changing the format below.
        dataSize = body.len + otherHeaders.len + serverInfo.len + 120
      requestData.sendQueue.setLen(origLen + dataSize)
      var pos = origLen
      let respCode = $code
      let bodyLen = $body.len

      appendAll(
        "HTTP/1.1 ", respCode,
        "\c\LContent-Length: ", bodyLen,
        "\c\LDate: ", serverDate,
        otherHeaders,
        "\c\L\c\L",
        body
      )
      requestData.sendQueue.setLen(pos)
    req.selector.updateHandle(req.client, {Event.Read, Event.Write})

  proc resp*(req: Request, code: HttpCode) =
    ## Responds with the specified HttpCode. The body of the response
    ## is the same as the HttpCode description.
    req.resp(code, $code)

  proc resp*(req: Request, body: sink string, code = Http200) {.inline.} =
    ## Sends a HTTP 200 OK response with the specified body.
    ##
    ## **Warning:** This can only be called once in the OnRequest callback.
    req.resp(code, body)
elif supranimServer == "mummy":
  # todo
  discard
  # import pkg/mummy
  # proc runServer*(onRequest: RequestHandler) =
  #   let server = mummy.newServer(onRequest)
elif supranimServer == "experimental":
  # todo
  discard
  # include ./server/experimental