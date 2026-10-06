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
  doAssert sizeof(curl_off_t) == 8
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
  var item: WebSocketResult
  doAssert not client.pollForResult(item)
  alias.abort()
  client.close()
  doAssert not client.waitForResult(item)
  close(WebSocketClient(nil))
  abort(WebSocketClient(nil))

block failedConnectReuse:
  let client = newWebSocketClient(maxConnections = 1, bypassProxy = true)
  try:
    for url in ["", "http://example.com/", "ws:///", "ws://user:pass@localhost/",
        "ws://localhost/\n"]:
      let failed = client.connect(url)
      doAssert failed.error.kind != teNone
      var completion: WebSocketResult
      var event: WebSocketEvent
      doAssert not client.pollForResult(completion)
      doAssert not client.pollForEvent(failed.connectionId, event)
  finally:
    client.close()

block executionStyles:
  let client = newWebSocketClient(maxConnections = 1, bypassProxy = true)
  try:
    let submitted = client.startConnect("http://example.com/")
    var completion: WebSocketResult
    doAssert client.waitForResult(completion)
    doAssert completion.operationId == submitted.operationId
    client.closeConnection(submitted.connectionId)
    doAssert client.connect("http://example.com/").error.kind != teNone
  finally:
    client.close()

block sharedClose:
  let client = newWebSocketClient(defaultTimeoutMs = 0, maxMessageBytes = 0)
  let alias = client
  alias.close()
  client.close()

block explicitClose:
  let client = newWebSocketClient()
  client.close()

echo "WebSocket ABI, input and ownership contracts passed"
