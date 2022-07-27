
method addCookieHeader*(res: var Response, cookie: ref Cookie) =
    ## Add a new `Cookie` to given Response instance.
    ## Do not call this method directly. Instead,
    ## you can use `newCookie()` method from `supranim/support/session` module
    if not res.headers.hasKey("set-cookie"):
        res.headers.table["set-cookie"] = newSeq[string]()
    res.headers.table["set-cookie"].add($cookie)

method deleteCookieHeader*(res: var Response, name: string) =
    ## Invalidate a Cookie on client side for the given `Response` 
    ## Do not call this method directly. Instead,
    ## you can use `deleteCookie()` method from `supranim/support/session` module
    ## TODO

template createNewUserSession(res: var Response) =
    # Create a new `UserSession` UUID and send the `Cookie` in the next `Response`
    var userSession = Session.newUserSession()
    res.sessionId = userSession.getUuid()
    res.addCookieHeader(userSession.getCookie("ssid"))

proc setUserSessionId(res: var Response, headerCookies: string) =
    # Set a new `UserSession` UUID or use the given one from `Request` if valid.
    if headerCookies.len == 0:
        createNewUserSession res
        return
    let reqCookies = parseCookies(headerCookies)
    if reqCookies.hasKey("ssid"):
        let ssid = reqCookies["ssid"].getValue()
        if Session.isValid(ssid):
            try:
                res.sessionId = uuid4(ssid)
            except ValueError:
                createNewUserSession res
        else: createNewUserSession res
    else: createNewUserSession res