import std/[assertions, nativesockets]
import relay/websocket
import relay/bindings/websockets
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
  initGlobal()
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
  cleanupGlobal()

block serviceOwnership:
  let client = newWebSocketService()
  let alias = client
  var item: WebSocketResult
  doAssert not client.pollForResult(item)
  alias.abort()
  client.close()
  doAssert not client.waitForResult(item)
  doAssertRaises IOError: discard client.startConnect("ws://127.0.0.1:1/")
  close(WebSocketService(nil))
  abort(WebSocketService(nil))
  discard newWebSocketService()

block disconnected:
  let client = newWebSocket()
  defer: client.close()
  doAssertRaises IOError: client.send("hello")
  doAssertRaises IOError: discard client.receive()
  for url in ["", "http://example.com/", "ws:///", "ws://user:pass@localhost/",
      "ws://localhost/#fragment", "ws://localhost/\n", "ws://localhost/\0hidden"]:
    doAssertRaises ValueError: client.connect(url)

block sharedClose:
  let client = newWebSocket(defaultTimeoutMs = 0, maxMessageBytes = 0)
  let alias = client
  alias.close()
  client.close()
  doAssertRaises IOError: client.connect("ws://127.0.0.1:1/")
  doAssertRaises IOError: client.send("")
  doAssertRaises IOError: discard alias.receive()
  close(WebSocket(nil))

block dropOwner:
  # Automatic destruction releases Easy before the matching global cleanup.
  discard newWebSocket()
  let client = newWebSocket()
  client.close()

echo "WebSocket ABI, input and ownership contracts passed"
echo "libcurl runtime version number: ", curl_version_info(CURLVERSION_FIRST).version_num
