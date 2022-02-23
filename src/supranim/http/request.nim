import selectors, net, nativesockets, os, httpcore, asyncdispatch,
       strutils, posix, parseutils, options, logging, times, json

type
    FdKind = enum
        Server, Client, Dispatcher

    Data = object
        fdKind: FdKind ## Determines the fd kind (server, client, dispatcher)
        ## - Client specific data.
        ## A queue of data that needs to be sent when the FD becomes writeable.
        sendQueue: string
        ## The number of characters in `sendQueue` that have been sent already.
        bytesSent: int
        ## Big chunk of data read from client during request.
        data: string
        ## Determines whether `data` contains "\c\l\c\l".
        headersFinished: bool
        ## Determines position of the end of "\c\l\c\l".
        headersFinishPos: int
        ## The address that a `client` connects from.
        ip: string
        ## Future for onRequest handler (may be nil).
        reqFut: Future[void]
        ## Identifier for current request. Mainly for better detection of cross-talk.
        requestID: uint

type
    Request* = object
        selector*: Selector[Data]
        client*: SocketHandle
        # Determines where in the data buffer this request starts.
        # Only used for HTTP pipelining.
        start*: int
        # Identifier used to distinguish requests.
        requestID*: uint

    OnRequest* = proc (req: Request): Future[void] {.gcsafe.}
