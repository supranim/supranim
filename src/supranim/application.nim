from std/nativesockets import Domain
from std/net import Port
from std/logging import Logger
export Port

type
    Application* = object
        port: Port                  ## Specify a port or let retrieve one automatically
        address: string             ## Specify a local IP address
        domain: Domain
        ssl: bool                   ## Boot in SSL mode (requires HTTPS Certificate)
        threads: int                ## Boot Supranim on a specific number of threads
        recyclable: bool            ## Whether to reuse current port or not
        loggers: seq[Logger]

proc init*[A: typedesc[Application]](app: A, port = Port(3399), address = "localhost", ssl = false, threads = 1): Application =
    ## Inititalize Application
    result = app(
        address: address,
        domain: Domain.AF_INET,
        port: port,
        ssl: ssl,
        threads: threads,
        recyclable: true
    )

proc getAddress*[A: Application](app: A): string {.inline.}  =
    ## Get the local address
    result = app.address

proc getPort*[A: Application](app: A): Port {.inline.} =
    ## Get the current Port
    result = app.port

proc hasSSL*[A: Application](app: A): bool {.inline.}  =
    ## Determine if ssl is turned on
    result = app.ssl

proc isMultithreading*[A: Application](app: A): bool {.inline.}  =
    ## Determine if application runs on multiple threads
    result = app.threads != 0 and app.threads != 1

proc getThreads*[A: Application](app: A): int {.inline.} =
    result = app.threads

proc getLoggers*[A: Application](app: A): seq[Logger] =
    result = app.loggers

proc getDomain*[A: Application](app: A): Domain =
    result = app.domain

proc isRecyclable*[A: Application](app: A): bool =
    ## Determine if current application Port can be reused
    result = app.recyclable
