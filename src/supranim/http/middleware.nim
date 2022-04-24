type
    MiddlewareStatus* = enum
        ## Identify status of current Middleware Response
        StatusError
        StatusOk

    MiddlewareBodyResponse* = object
        ## Middleware Body Response object containing `MiddlewareStatus`
        ## and a redirect URI based on either `StatusError` or `StatusOk`
        case status: MiddlewareStatus
        of StatusError:
            errorRedirectUri: string
        of StatusOk:
            okRedirectUri: string

    MiddlewareResponse* = tuple[status: bool, body: MiddlewareBodyResponse]

proc getMiddlewareStatus*[M: MiddlewareBodyResponse](body: M): MiddlewareStatus =
    ## Retrieve current Middleware Response Status
    result = body.status

proc getMiddlewareResponseStatusBool*[S: MiddlewareStatus](status: S): bool =
    ## Retrieve the Middleware Response Status as a boolean
    result = case status:
                of StatusError: false
                of StatusOk: true

proc getRedirectURI*[M: MiddlewareBodyResponse](body: M): string =
    ## Retrieve a string representing the redirect URI based on Middleware Status
    case body.getMiddlewareStatus():
    of StatusError:
        result = body.errorRedirectUri
    of StatusOk: 
        result = body.okRedirectUri

proc newMiddlewareResponse*(status: bool, redirectUri: string): MiddlewareResponse =
    ## Create a new Middleware Response
    var resp: MiddlewareBodyResponse
    case status:
        of true: resp = MiddlewareBodyResponse(status: StatusOk, okRedirectUri: redirectUri)
        of false: resp = MiddlewareBodyResponse(status: StatusError, errorRedirectUri: redirectUri)
    result = tuple[status: status, body: resp]
