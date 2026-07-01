#
# Supranim is a high-performance web framework for building
# web applications and microservices in Nim
# 
#   (c) 2026 LGPL-v3-or-later License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#

import pkg/powpow as pw
export pw.WsConnection, pw.WsFrameKind
export pw.WsOpenCb, pw.WsMessageCb, pw.WsCloseCb, pw.WsErrorCb
export pw.WsServer, pw.newWsServer
export pw.sendText, pw.sendBinary, pw.sendPing, pw.sendPong
export pw.closeWs, pw.websocketUpgrade

# Backward-compat aliases
type
  WebSocketConnection* = pw.WsConnection
  WebSocketFrameKind* = pw.WsFrameKind
  OpenCb* = pw.WsOpenCb
  MessageCb* = pw.WsMessageCb
  CloseCb* = pw.WsCloseCb
  ErrorCb* = pw.WsErrorCb
