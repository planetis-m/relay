## Real loopback peers exercise frame handling and shutdown through libcurl.
## Each socket is owned and closed by its thread; reads have bounded timeouts.
import relay/websocket
import std/[assertions, base64, locks, monotimes, net, os, sha1, strutils, times]
from std/nativesockets import getSockName

{.emit: """
#include <curl/curl.h>
#include <string.h>
static int protocol_test_available(void) {
  const curl_version_info_data *info = curl_version_info(CURLVERSION_NOW);
  if(info->version_num < 0x080e00) return 0;
  for(const char *const *p = info->protocols; *p; ++p)
    if(strcmp(*p, "ws") == 0) return 1;
  return 0;
}
""".}
proc protocolTestAvailable(): bool {.importc: "protocol_test_available", nodecl.}

type
  PeerMode = enum
    pmEcho, pmOrdered, pmSilentClose, pmCancel, pmInvalidText
  PeerObj = object
    lock: Lock
    readyCond: Cond
    ready, dataRead: bool
    port: Port
    error: string
    mode: PeerMode
    thread: Thread[ptr PeerObj]
  Peer = ref PeerObj
  Frame = object
    opcode: int
    data: string

proc readBytes(socket: Socket; count: int): string =
  if count == 0: return ""
  result = socket.recv(count, timeout = 3_000)
  if result.len != count:
    raise newException(IOError, "short peer read: " & $result.len & "/" & $count)

proc upgrade(socket: Socket) =
  var headers: string
  while not headers.endsWith("\r\n\r\n"):
    headers.add(socket.readBytes(1))
    doAssert headers.len <= 8_192
  var key: string
  for line in headers.splitLines():
    if line.toLowerAscii().startsWith("sec-websocket-key:"):
      key = line.split(':', maxsplit = 1)[1].strip()
  doAssert key.len > 0
  let accept = encode(Sha1Digest(secureHash(key & "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")))
  socket.send("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" &
    "Connection: Upgrade\r\nSec-WebSocket-Accept: " & accept & "\r\n\r\n")

proc wireFrame(opcode: int; data: string; final = true): string =
  result.add(char(opcode or (if final: 0x80 else: 0)))
  if data.len < 126:
    result.add(char(data.len))
  else:
    doAssert data.len <= 65_535
    result.add(char(126))
    result.add(char(data.len shr 8))
    result.add(char(data.len and 255))
  result.add(data)

proc readFrame(socket: Socket): Frame =
  let header = socket.recv(2, timeout = 3_000)
  if header.len == 0: return Frame(opcode: -1)
  doAssert header.len == 2
  doAssert (ord(header[0]) and 0xf0) == 0x80, "expected final frame without extensions"
  doAssert (ord(header[1]) and 0x80) != 0, "client frame must be masked"
  result.opcode = ord(header[0]) and 15
  var length = ord(header[1]) and 127
  if length == 126:
    let size = socket.readBytes(2)
    length = (ord(size[0]) shl 8) or ord(size[1])
  elif length == 127:
    let size = socket.readBytes(8)
    length = 0
    for ch in size:
      doAssert length <= 1_048_576 shr 8, "unexpectedly large client frame"
      length = (length shl 8) or ord(ch)
  doAssert length <= 1_048_576
  let mask = socket.readBytes(4)
  result.data = socket.readBytes(length)
  for i in 0..<result.data.len:
    result.data[i] = char(ord(result.data[i]) xor ord(mask[i mod 4]))

proc largePayload(): string =
  result = newString(48 * 1024)
  for i in 0..<result.len: result[i] = char(i mod 256)

proc peerMain(peerPtr: ptr PeerObj) {.thread, raises: [].} =
  let peer = cast[Peer](peerPtr)
  var listener: Socket
  var socket: owned(Socket)
  try:
    listener = newSocket(buffered = false)
    listener.bindAddr(Port(0), "127.0.0.1")
    listener.listen()
    acquire(peer.lock)
    peer.port = getSockName(listener.getFd())
    peer.ready = true
    signal(peer.readyCond)
    release(peer.lock)
    listener.accept(socket)
    socket.upgrade()
    case peer.mode
    of pmEcho:
      for expected in [Frame(opcode: 1, data: ""), Frame(opcode: 2, data: "\0\xff"),
          Frame(opcode: 2, data: largePayload())]:
        let frame = socket.readFrame()
        doAssert frame.opcode == expected.opcode and frame.data == expected.data
        socket.send(wireFrame(frame.opcode, frame.data))
      let close = socket.readFrame()
      doAssert close.opcode == 8
      socket.send(wireFrame(8, close.data))
      doAssert socket.readFrame().opcode == -1, "duplicate CLOSE"
    of pmOrdered:
      socket.send(wireFrame(1, "hel", final = false) & wireFrame(9, "probe") &
        wireFrame(0, "lo") & wireFrame(2, "") & wireFrame(2, "\0\xff") &
        wireFrame(8, "\x03\xe8bye"))
      var pongCount, closeCount: int
      while pongCount == 0 or closeCount == 0:
        let frame = socket.readFrame()
        case frame.opcode
        of 10:
          inc pongCount
          doAssert frame.data == "probe"
        of 8: inc closeCount
        else: doAssert false, "unexpected response to peer control frames"
      doAssert pongCount == 1 and closeCount == 1
      doAssert socket.readFrame().opcode == -1, "duplicate control frame"
    of pmSilentClose:
      doAssert socket.readFrame().opcode == 8
      # No reply: the client must finish using its original close deadline.
      doAssert socket.readFrame().opcode == -1, "duplicate CLOSE"
    of pmCancel:
      let frame = socket.readFrame()
      doAssert frame.opcode == 1 and frame.data == "unread completion"
      acquire(peer.lock)
      peer.dataRead = true
      release(peer.lock)
      doAssert socket.readFrame().opcode == -1, "cancel/abort must not start a handshake"
    of pmInvalidText:
      socket.send(wireFrame(1, "valid") & wireFrame(1, "\xff"))
      doAssert socket.readFrame().opcode == -1
  except CatchableError:
    acquire(peer.lock)
    peer.error = getCurrentExceptionMsg()
    peer.ready = true
    signal(peer.readyCond)
    release(peer.lock)
  finally:
    if socket != nil: socket.close()
    if listener != nil: listener.close()

proc startPeer(mode: PeerMode): Peer =
  new(result)
  result.mode = mode
  initLock(result.lock)
  initCond(result.readyCond)
  createThread(result.thread, peerMain, cast[ptr PeerObj](result))
  acquire(result.lock)
  while not result.ready: wait(result.readyCond, result.lock)
  let error = result.error
  release(result.lock)
  doAssert error.len == 0, error

proc finishPeer(peer: Peer) =
  # Wake accept if connection setup failed; socket cleanup stays in the peer thread.
  try:
    let wake = newSocket()
    wake.connect("127.0.0.1", peer.port)
    wake.close()
  except CatchableError: discard
  joinThread(peer.thread)
  let error = peer.error
  deinitCond(peer.readyCond)
  deinitLock(peer.lock)
  doAssert error.len == 0, error

proc open(client: WebSocketClient; peer: Peer): ConnectionId =
  let connected = client.connect("ws://127.0.0.1:" & $int(peer.port), timeoutMs = 2_000)
  doAssert connected.error.kind == teNone, connected.error.message
  connected.connectionId

proc expectMessage(client: WebSocketClient; id: ConnectionId; kind: MessageKind;
    data: string) =
  let received = client.receive(id, timeoutMs = 2_000)
  doAssert received.kind == wrMessage, $received.kind & ": " & received.error.message
  doAssert received.message.kind == kind and received.message.data == data

proc main() =
  if not protocolTestAvailable():
    echo "Skipping WebSocket protocol tests: requires WebSocket-enabled libcurl 8.14+"
    return

  block roundtrip:
    let peer = startPeer(pmEcho)
    let client = newWebSocketClient(bypassProxy = true, closeTimeoutMs = 500)
    try:
      let id = client.open(peer)
      doAssert client.receive(id, timeoutMs = 20).kind == wrTimedOut
      for message in [WebSocketMessage(kind: wmText, data: ""),
          WebSocketMessage(kind: wmBinary, data: "\0\xff"),
          WebSocketMessage(kind: wmBinary, data: largePayload())]:
        let sent = client.send(id, message, timeoutMs = 2_000)
        doAssert sent.connectionId == id and sent.error.kind == teNone, sent.error.message
        client.expectMessage(id, message.kind, message.data)
      client.closeConnection(id)
      var event: WebSocketEvent
      doAssert not client.pollForEvent(id, event)
    finally:
      client.abort()
      peer.finishPeer()

  block retained_order:
    let peer = startPeer(pmOrdered)
    let client = newWebSocketClient(bypassProxy = true, maxEvents = 8, closeTimeoutMs = 500)
    try:
      let id = client.open(peer)
      client.expectMessage(id, wmText, "hello")
      client.close()
      client.expectMessage(id, wmBinary, "")
      client.expectMessage(id, wmBinary, "\0\xff")
      let terminal = client.receive(id)
      doAssert terminal.kind == wrClosed and terminal.error.kind == teCanceled
      var event: WebSocketEvent
      doAssert not client.pollForEvent(id, event), "terminal delivered twice"
    finally:
      client.abort()
      peer.finishPeer()

  block bounded_close:
    let peer = startPeer(pmSilentClose)
    let client = newWebSocketClient(bypassProxy = true, closeTimeoutMs = 80)
    try:
      let id = client.open(peer)
      let started = getMonoTime()
      client.startCloseConnection(id)
      client.startCloseConnection(id)
      client.close()
      doAssert (getMonoTime() - started).inMilliseconds < 1_500
      doAssert client.receive(id).kind == wrClosed
    finally:
      client.abort()
      peer.finishPeer()

  for cancelFirst in [false, true]:
    let peer = startPeer(pmCancel)
    let client = newWebSocketClient(bypassProxy = true, maxCommands = 1, closeTimeoutMs = 5_000)
    try:
      let id = client.open(peer)
      let operation = client.startSend(id, WebSocketMessage(kind: wmText, data: "unread completion"))
      let deadline = getMonoTime() + initDuration(milliseconds = 2_000)
      var dataRead = false
      while not dataRead and getMonoTime() < deadline:
        acquire(peer.lock)
        dataRead = peer.dataRead
        release(peer.lock)
        if not dataRead: sleep(1)
      doAssert dataRead
      doAssertRaises IOError:
        discard client.startSend(id, WebSocketMessage(kind: wmText, data: "refused"))
      let started = getMonoTime()
      if cancelFirst: client.cancel(id)
      client.abort()
      doAssert (getMonoTime() - started).inMilliseconds < 1_500
      var completion: WebSocketResult
      doAssert client.waitForResult(completion)
      doAssert completion.connectionId == id and completion.operationId == operation
      doAssert completion.error.kind in {teNone, teCanceled}
      doAssert not client.waitForResult(completion), "completion delivered twice"
      let terminal = client.receive(id)
      doAssert terminal.kind == wrClosed and terminal.error.kind == teCanceled
      var event: WebSocketEvent
      doAssert not client.pollForEvent(id, event), "terminal delivered twice"
    finally:
      client.abort()
      peer.finishPeer()

  block invalid_text:
    let peer = startPeer(pmInvalidText)
    let client = newWebSocketClient(bypassProxy = true)
    try:
      let id = client.open(peer)
      client.expectMessage(id, wmText, "valid")
      let terminal = client.receive(id, timeoutMs = 2_000)
      doAssert terminal.kind == wrClosed and terminal.error.kind == teProtocol
    finally:
      client.abort()
      peer.finishPeer()

  echo "WebSocket loopback protocol and shutdown contracts passed"

when isMainModule:
  main()
