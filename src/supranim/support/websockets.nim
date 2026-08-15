## This module provides a simple WebSocket client and server implementation
## based on the Libdatachannel library.
## 
## It is designed to be used with the Supranim framework
## for building web applications and microservices in Nim.
##
## The WebSocket client and server can be used to establish
## real-time communication between the server and clients.
##
## The client can connect to a WebSocket server and send/receive messages,
## while the server can accept incoming WebSocket connections and handle
## messages from clients.
##
## The implementation uses the Libdatachannel library for WebSocket
## functionality, which provides a simple and efficient way to handle
## WebSocket connections.

import pkg/libdatachannel
