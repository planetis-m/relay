import std/[assertions, nativesockets]
import relay/websocket
import relay/bindings/curl
import relay/curl_wrap

{.emit: """
#include <curl/curl.h>
#include <stddef.h>
static size_t ws_frame_size(void) { return sizeof(struct curl_ws_frame); }
static size_t ws_frame_offset(void) { return offsetof(struct curl_ws_frame, bytesleft); }
static size_t ws_wait_size(void) { return sizeof(struct curl_waitfd); }
static size_t ws_socket_size(void) { return sizeof(curl_socket_t); }
""".}
proc frameSize(): csize_t {.importc: "ws_frame_size", nodecl.}
proc frameOffset(): csize_t {.importc: "ws_frame_offset", nodecl.}
proc waitSize(): csize_t {.importc: "ws_wait_size", nodecl.}
proc socketSize(): csize_t {.importc: "ws_socket_size", nodecl.}

block abi:
  doAssert frameSize() == sizeof(curl_ws_frame).csize_t
  doAssert frameOffset() == offsetOf(curl_ws_frame, bytesleft).csize_t
  doAssert waitSize() == sizeof(curl_waitfd).csize_t
  doAssert socketSize() == sizeof(SocketHandle).csize_t

block curlOwners:
  initCurl()
  try:
    block:
      var easy = initEasy()
      easy = initEasy()
      easy = default(Easy)
      var list: Slist
      list.addHeader("X-Test: first")
      var replacement: Slist
      replacement.addHeader("X-Test: second")
      list = move replacement
      var multi = initMulti()
      multi = initMulti()
      multi = default(Multi)
  finally:
    cleanupCurl()

block serviceOwnership:
  let client = newWebSocketClient()
  let alias = client
  alias.abort()
  client.close()

block failedConnectReuse:
  let client = newWebSocketClient(maxConnections = 1, maxCommands = 1, bypassProxy = true)
  try:
    # Both slots must be released by a failed blocking connect.
    for attempt in 0..<2:
      doAssert client.connect("ws:///").error.kind != teNone
  finally:
    client.close()

block executionStyles:
  let client = newWebSocketClient(maxConnections = 1, maxCommands = 1, bypassProxy = true)
  try:
    let submitted = client.startConnect("ws:///")
    var completion: WebSocketResult
    doAssert client.waitForResult(completion)
    doAssert completion.operationId == submitted.operationId
    client.closeConnection(submitted.connectionId)
    doAssert client.connect("ws:///").error.kind != teNone
  finally:
    client.close()

echo "WebSocket ABI and ownership contracts passed"
