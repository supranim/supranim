
import posix

proc bindUnixSocketListener*(base: ptr event_base, socketPath: string,
                             flags: cuint = LEV_OPT_CLOSE_ON_FREE or LEV_OPT_REUSEABLE,
                             backlog: cint = 128): ptr evconnlistener =
  ## Creates and binds a Libevent evconnlistener to a Unix domain socket path.
  ## Returns a listener attached to `base`. Use `evhttp_bind_listener` to attach it to an evhttp.
  var sock: Sockaddr_un
  zeroMem(addr(sock), sizeof(sock))
  sock.sun_family = TSa_Family(AF_UNIX)

  # Ensure sun_path is NUL-terminated and fits
  let maxLen = sock.sun_path.len - 1
  let copyLen = min(socketPath.len, maxLen)
  for i in 0 ..< copyLen:
    sock.sun_path[i] = socketPath[i]
  sock.sun_path[copyLen] = '\0'

  # Remove stale socket, otherwise bind can fail
  discard unlink(socketPath)

  # Create listener bound to AF_UNIX address
  let saLen = sizeof(sock).cint
  let lev = evconnlistener_new_bind(
    base,
    nil,                    # accept callback not needed; evhttp will consume it
    nil,                    # user_arg
    flags,
    backlog,
    cast[ptr SockAddr](addr(sock)),
    saLen
  )
  assert lev != nil, "Failed to create evconnlistener for unix socket"
  return lev

proc startUnixWithListener*(server: var WebServer, socketPath: string, onRequest: OnRequest,
                            startupCallback: StartupCallback = nil) =
  ## Starts the HTTP server on a Unix domain socket using evconnlistener_new_bind
  assert server.httpServer != nil
  assert server.base != nil

  # Optional: suppress AF_UNIX getnameinfo noise and avoid aborts
  # nim_event_set_log_callback_from_nim(libeventLogCb)
  # event_set_fatal_callback(cast[EventFatalCb](libeventFatalCb))

  # Create bound listener
  let listener = bindUnixSocketListener(server.base, socketPath)
  assert listener != nil
  # Attach listener to evhttp
  discard evhttp_bind_listener(server.httpServer, listener)
  # Set request handler
  evhttp_set_gencb(server.httpServer, initialOnRequest, cast[pointer](onRequest))

  if startupCallback != nil:
    startupCallback()

  # Run loop
  assert event_base_dispatch(server.base) > -1

  # Cleanup: evhttp_free will not free the listener (LEV_OPT_CLOSE_ON_FREE closes fd)
  evconnlistener_free(listener)
  evhttp_free(server.httpServer)
  event_base_free(server.base)
