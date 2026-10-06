## Persistent text/binary connections with blocking and incremental operations.
## Requires --threads:on --mm:atomicArc and WebSocket-enabled libcurl 8.14+.
## Call close or abort before releasing an owner; shutdown belongs to its creating thread.
## Submission and connection control require an open client; retrieval works after shutdown.
import std/[base64, deques, locks, monotimes, sha1, strutils, sysrand, times, unicode]
import ./[curl_wrap, transport_errors]
import ./bindings/curl
export transport_errors

type
  ConnectionId* = distinct int64
  OperationId* = distinct int64
  MessageKind* = enum
    wmText, wmBinary
  WebSocketMessage* = object
    kind*: MessageKind
    data*: string
  WebSocketResult* = object ## Completion of an accepted connect or send operation.
    connectionId*: ConnectionId
    operationId*: OperationId
    error*: TransportError
  WebSocketEventKind* = enum
    weMessage, weClosed
  WebSocketEvent* = object ## Received message or terminal connection status.
    connectionId*: ConnectionId
    kind*: WebSocketEventKind
    message*: WebSocketMessage
    error*: TransportError
  WebSocketReceiveKind* = enum
    wrMessage, wrClosed, wrTimedOut
  WebSocketReceiveResult* = object ## A message, terminal status or receive deadline expiry.
    kind*: WebSocketReceiveKind
    message*: WebSocketMessage ## Present only for wrMessage.
    error*: TransportError
  CommandKind = enum
    wcConnect, wcSend
  ClientState = enum
    csRunning, csStopping, csAborting, csStopped
  Command = object
    kind: CommandKind
    connectionId: ConnectionId
    operationId: OperationId
    deadline: MonoTime
    url: string
    message: WebSocketMessage
  StopRequest = enum
    srNone, srClose, srCancel
  Handshake = object
    expected: string
    accepted: bool
  ConnectionState = enum
    cnConnecting, cnOpen, cnClosing, cnFinished
  ConnectionFlag = enum
    cfAttached, cfCloseSent, cfPeerClosed, cfFrameStarted, cfIncomingActive
  Mailbox = ref object
    # Shared under client.lock; only the worker changes the connection phase.
    id: ConnectionId
    state: ConnectionState
    request: StopRequest
    terminalError: TransportError
    events: Deque[WebSocketEvent]
    queuedBytes: int
  Connection = ref object
    # Owned only by the worker; stable storage for curl's handshake callback.
    mailbox: Mailbox
    easy: Easy
    headers: Slist
    handshake: Handshake
    flags: set[ConnectionFlag]
    connectCommand: Command
    sends: Deque[Command]
    offset: int
    incoming: WebSocketMessage
    control: string
    controls: Deque[tuple[data: string, flags: cuint]]
    controlOffset: int
    closeDeadline: MonoTime
  WebSocketClientObj = object
    lock: Lock
    resultCond: Cond
    thread: Thread[ptr WebSocketClientObj]
    state: ClientState
    closed: bool # Owner-only: worker joined and synchronization released.
    multi: Multi
    commands: Deque[Command]
    results: Deque[WebSocketResult]
    connections: seq[Mailbox] # Queued attempts and retained terminal events.
    proxy, caInfo: string
    nextConnection, nextOperation: int64
    outstanding: int # Accepted operations, including results awaiting consumption.
    maxConnections, maxCommands, maxEvents, maxQueuedBytes: int
    defaultTimeoutMs, maxMessageBytes, closeTimeoutMs: int
    bypassProxy: bool
  WebSocketClient* = ref WebSocketClientObj ## Shared owner of persistent connections.

proc `==`*(a, b: ConnectionId): bool {.borrow.}
proc `==`*(a, b: OperationId): bool {.borrow.}

proc timeout(client: WebSocketClientObj; timeoutMs: int): int =
  if timeoutMs > 0: min(timeoutMs, cint.high.int) else: client.defaultTimeoutMs

proc connection(client: WebSocketClientObj; id: ConnectionId): Mailbox =
  result = nil
  for item in client.connections:
    if item.id == id: return item

proc completion(client: var WebSocketClientObj; cmd: sink Command; error = TransportError()) =
  acquire(client.lock)
  client.results.addLast(WebSocketResult(connectionId: cmd.connectionId,
    operationId: cmd.operationId, error: error))
  release(client.lock)

proc finish(client: var WebSocketClientObj; conn: Connection;
    error: sink TransportError) =
  if conn.mailbox.state == cnFinished: return
  if conn.mailbox.state == cnConnecting:
    client.completion(move conn.connectCommand, error)
  while conn.sends.len > 0:
    client.completion(conn.sends.popFirst(), error)
  if cfAttached in conn.flags:
    try:
      client.multi.removeHandle(conn.easy)
    except IOError:
      discard
    conn.flags.excl(cfAttached)
  conn.easy = default(Easy)
  reset(conn.headers)
  acquire(client.lock)
  conn.mailbox.terminalError = error
  conn.mailbox.state = cnFinished
  release(client.lock)

proc headerCb(buffer: ptr char; size, nitems: csize_t; userdata: pointer): csize_t {.cdecl.} =
  let total = size * nitems
  result = 0
  if total <= 8192:
    let handshake = cast[ptr Handshake](userdata)
    var line = newString(total.int)
    if total > 0: copyMem(addr line[0], buffer, total.int)
    let colon = line.find(':')
    var valid = true
    if colon > 0:
      case line[0..<colon].toLowerAscii()
      of "sec-websocket-accept":
        valid = not handshake.accepted and line[colon + 1..^1].strip() == handshake.expected
        if valid: handshake.accepted = true
      of "sec-websocket-extensions", "sec-websocket-protocol": valid = false
      else: discard
    if valid: result = total

proc configure(client: var WebSocketClientObj; conn: Connection) =
  let duration = max(1, int((conn.connectCommand.deadline - getMonoTime()).inMilliseconds))
  conn.easy = initEasy()
  let key = encode(urandom(16))
  conn.handshake = Handshake(expected:
    encode(Sha1Digest(secureHash(key & "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))))
  conn.headers.addHeader("Sec-WebSocket-Key: " & key)
  conn.easy.setUrl(conn.connectCommand.url)
  conn.easy.setOpt(CURLOPT_PROTOCOLS_STR, "ws,wss".cstring)
  conn.easy.setOpt(CURLOPT_DISALLOW_USERNAME_IN_URL, 1.clong)
  conn.easy.setHeaders(conn.headers)
  conn.easy.setHeaderCallback(headerCb, addr conn.handshake)
  conn.easy.setTimeoutMs(duration)
  conn.easy.setConnectTimeoutMs(duration)
  conn.easy.setSslVerify(true, true)
  conn.easy.setFollowRedirects(false, 0)
  if client.bypassProxy or client.proxy.len > 0:
    let proxy = if client.bypassProxy: "" else: client.proxy
    conn.easy.setOpt(CURLOPT_PROXY, proxy.cstring)
  if client.caInfo.len > 0:
    conn.easy.setOpt(CURLOPT_CAINFO, client.caInfo.cstring)
  conn.easy.setOpt(CURLOPT_CONNECT_ONLY, 2.clong)
  conn.easy.setOpt(CURLOPT_WS_OPTIONS, CURLWS_NOAUTOPONG)
  client.multi.addHandle(conn.easy)
  conn.flags.incl(cfAttached)

proc publish(client: var WebSocketClientObj; conn: Connection) =
  acquire(client.lock)
  try:
    if conn.mailbox.events.len >= client.maxEvents or
        conn.incoming.data.len > client.maxQueuedBytes - conn.mailbox.queuedBytes:
      raise newException(IOError, "WebSocket event queue overflow")
    inc conn.mailbox.queuedBytes, conn.incoming.data.len
    conn.mailbox.events.addLast(WebSocketEvent(connectionId: conn.mailbox.id,
      kind: weMessage, message: move conn.incoming))
  finally:
    release(client.lock)

proc requestClose(client: var WebSocketClientObj; conn: Connection; payload: sink string = "") =
  if conn.mailbox.state == cnOpen:
    if conn.controls.len >= 8:
      raise newException(IOError, "WebSocket control queue overflow")
    conn.controls.addLast((payload, CURLWS_CLOSE))
    conn.closeDeadline = getMonoTime() + initDuration(milliseconds = client.closeTimeoutMs)
    acquire(client.lock)
    conn.mailbox.state = cnClosing
    release(client.lock)

proc readFrames(client: var WebSocketClientObj; conn: Connection): CURLcode =
  result = CURLE_OK
  var buffer: array[16 * 1024, char]
  for turn in 0..<4:
    if cfPeerClosed in conn.flags: break
    var received: csize_t
    var frame: tuple[flags: cuint, bytesLeft: curl_off_t]
    result = conn.easy.recvFrame(addr buffer[0], buffer.len.csize_t, received, frame)
    if result != CURLE_OK: break
    let count = received.int # libcurl writes at most buffer.len bytes.
    let flags = frame.flags
    if (flags and (CURLWS_TEXT or CURLWS_BINARY)) != 0:
      let kind = if (flags and CURLWS_BINARY) != 0: wmBinary else: wmText
      if cfIncomingActive in conn.flags and conn.incoming.kind != kind:
        raise newException(IOError, "WebSocket fragment type changed")
      let available = client.maxMessageBytes - conn.incoming.data.len
      if count > available or frame.bytesLeft > (available - count).curl_off_t:
        raise newException(IOError, "WebSocket message exceeds byte limit")
      conn.flags.incl(cfIncomingActive)
      conn.incoming.kind = kind
      let start = conn.incoming.data.len
      conn.incoming.data.setLen(start + count)
      if count > 0: copyMem(addr conn.incoming.data[start], addr buffer[0], count)
      if frame.bytesLeft == 0 and (flags and CURLWS_CONT) == 0:
        if kind == wmText and conn.incoming.data.validateUtf8() >= 0:
          raise newException(IOError, "Invalid UTF-8 WebSocket message")
        client.publish(conn)
        conn.flags.excl(cfIncomingActive)
    elif (flags and (CURLWS_PING or CURLWS_CLOSE)) != 0:
      let available = 125 - conn.control.len
      if count > available or frame.bytesLeft > (available - count).curl_off_t:
        raise newException(IOError, "Invalid WebSocket control size")
      let start = conn.control.len
      conn.control.setLen(start + count)
      if count > 0: copyMem(addr conn.control[start], addr buffer[0], count)
      if frame.bytesLeft == 0:
        let reply = if (flags and CURLWS_CLOSE) != 0: CURLWS_CLOSE else: CURLWS_PONG
        if reply == CURLWS_CLOSE:
          if conn.control.len == 1 or
              (conn.control.len > 2 and conn.control[2..^1].validateUtf8() >= 0):
            raise newException(IOError, "Invalid WebSocket close payload")
          if conn.control.len >= 2:
            let code = ord(conn.control[0]) * 256 + ord(conn.control[1])
            if code < 1000 or code >= 5000 or code in [1004, 1005, 1006, 1015] or
                (code >= 1016 and code < 3000):
              raise newException(IOError, "Invalid WebSocket close code")
          conn.flags.incl(cfPeerClosed)
          client.requestClose(conn, move conn.control)
        else:
          if conn.controls.len >= 8:
            raise newException(IOError, "WebSocket control queue overflow")
          conn.controls.addLast((move conn.control, reply))
    elif (flags and CURLWS_PONG) == 0:
      raise newException(IOError, "Unsupported WebSocket frame")

proc writeFrame(conn: Connection; data: string; flags: cuint; offset: var int): CURLcode =
  var sent: csize_t
  let buffer = if offset == data.len: nil else: cast[pointer](addr data[offset])
  result = conn.easy.sendFrame(buffer, (data.len - offset).csize_t, sent, 0, flags)
  inc offset, sent.int

proc writeData(conn: Connection; cmd: Command): CURLcode =
  # Explicit partial-frame mode bounds masking/copy work on every worker turn.
  let data = cmd.message.data
  let count = min(16 * 1024, data.len - conn.offset)
  let buffer = if count == 0: nil else: cast[pointer](addr data[conn.offset])
  let kind = if cmd.message.kind == wmText: CURLWS_TEXT else: CURLWS_BINARY
  let flags = if data.len == 0: kind else: kind or CURLWS_OFFSET
  let size = if cfFrameStarted notin conn.flags: data.len.int64 else: 0'i64
  var sent: csize_t
  result = conn.easy.sendFrame(buffer, count.csize_t, sent, size, flags)
  conn.flags.incl(cfFrameStarted)
  inc conn.offset, sent.int

proc writeFrames(client: var WebSocketClientObj; conn: Connection): CURLcode =
  # Finish either partially sent frame before switching between data/control queues.
  result = CURLE_OK
  if conn.sends.len > 0 and conn.controlOffset == 0 and
      (cfFrameStarted in conn.flags or (conn.mailbox.state != cnClosing and conn.controls.len == 0)):
    let cmd {.cursor.} = conn.sends.peekFirst()
    result = conn.writeData(cmd)
    if result == CURLE_OK and conn.offset == cmd.message.data.len:
      client.completion(conn.sends.popFirst())
      conn.offset = 0
      conn.flags.excl(cfFrameStarted)
  if result == CURLE_OK and cfFrameStarted notin conn.flags and conn.controls.len > 0:
    let control {.cursor.} = conn.controls.peekFirst()
    result = conn.writeFrame(control.data, control.flags, conn.controlOffset)
    if result == CURLE_OK and conn.controlOffset == control.data.len:
      if control.flags == CURLWS_CLOSE: conn.flags.incl(cfCloseSent)
      discard conn.controls.popFirst()
      conn.controlOffset = 0

proc processCommands(client: var WebSocketClientObj; active: var seq[Connection]) =
  var commands = Deque[Command]()
  acquire(client.lock)
  swap(commands, client.commands)
  release(client.lock)
  while commands.len > 0:
    var cmd = commands.popFirst()
    case cmd.kind
    of wcConnect:
      acquire(client.lock)
      let mailbox = client.connection(cmd.connectionId)
      release(client.lock)
      let conn = Connection(mailbox: mailbox, connectCommand: cmd)
      active.add(conn)
      if getMonoTime() >= conn.connectCommand.deadline:
        client.finish(conn, newTransportError(teTimeout, "WebSocket connect timed out"))
      else:
        try:
          client.configure(conn)
        except CatchableError:
          client.finish(conn, newTransportError(teNetwork,
            "WebSocket connect failed: " & getCurrentExceptionMsg()))
    of wcSend:
      var conn {.cursor.}: Connection
      for item in active:
        if item.mailbox.id == cmd.connectionId:
          conn = item
          break
      if conn == nil or conn.mailbox.state != cnOpen:
        client.completion(cmd, newTransportError(teCanceled, "WebSocket connection unavailable"))
      else:
        conn.sends.addLast(cmd)

proc upgrades(client: var WebSocketClientObj; connections: seq[Connection]) =
  var queued: int
  var msg: CURLMsg
  while client.multi.tryInfoRead(msg, queued):
    if msg.msg == CURLMSG_DONE:
      for conn in connections:
        if conn.mailbox.state == cnConnecting and conn.easy.handleKey() == msg.handleKey():
          if getMonoTime() >= conn.connectCommand.deadline:
            client.finish(conn, newTransportError(teTimeout, "WebSocket connect timed out"))
          elif msg.data.result != CURLE_OK:
            client.finish(conn, newTransportError(classifyTransportError(msg.data.result),
              "WebSocket connect failed: " & $curl_easy_strerror(msg.data.result),
              msg.data.result.int))
          elif conn.easy.responseCode() != 101 or not conn.handshake.accepted:
            client.finish(conn, newTransportError(teProtocol, "WebSocket upgrade refused"))
          else:
            acquire(client.lock)
            conn.mailbox.state = cnOpen
            release(client.lock)
            client.completion(move conn.connectCommand)
          break

proc serviceConnection(client: var WebSocketClientObj; conn: Connection; state: ClientState) =
  acquire(client.lock)
  let request = conn.mailbox.request
  release(client.lock)
  if request == srCancel or state == csAborting or
      (state == csStopping and conn.mailbox.state == cnConnecting):
    client.finish(conn, newTransportError(teCanceled, "WebSocket canceled"))
  else:
    case conn.mailbox.state
    of cnConnecting:
      if request == srClose:
        client.finish(conn, newTransportError(teCanceled, "WebSocket closed"))
      elif getMonoTime() >= conn.connectCommand.deadline:
        client.finish(conn, newTransportError(teTimeout, "WebSocket connect timed out"))
    of cnOpen, cnClosing:
      if request == srClose or state == csStopping: client.requestClose(conn)
      var expired = false
      let now = getMonoTime()
      for cmd in conn.sends:
        if now >= cmd.deadline:
          expired = true
          break
      if expired:
        client.finish(conn, newTransportError(teTimeout, "WebSocket send timed out"))
      else:
        var code = client.readFrames(conn)
        if code == CURLE_OK or code == CURLE_AGAIN:
          code = client.writeFrames(conn)
        if code != CURLE_OK and code != CURLE_AGAIN:
          client.finish(conn, newTransportError(classifyTransportError(code),
            "WebSocket transfer failed: " & $curl_easy_strerror(code), code.int))
        elif conn.mailbox.state == cnClosing and ({cfPeerClosed, cfCloseSent} <= conn.flags or
            getMonoTime() >= conn.closeDeadline):
          let reason = if cfPeerClosed in conn.flags:
            "Peer closed the WebSocket connection"
            else: "WebSocket closed"
          client.finish(conn, newTransportError(teCanceled, reason))
    of cnFinished:
      discard

proc workerMain(client: ptr WebSocketClientObj) {.thread.} =
  var active: seq[Connection] = @[]
  var fds: seq[curl_waitfd] = @[]
  try:
    while true:
      client[].processCommands(active)
      discard client.multi.perform()
      client[].upgrades(active)
      fds.setLen(0)
      acquire(client.lock)
      let state = client.state
      release(client.lock)
      var kept = 0
      for i in 0..<active.len:
        let conn {.cursor.} = active[i]
        if conn.mailbox.state != cnFinished:
          try:
            client[].serviceConnection(conn, state)
            if conn.mailbox.state in {cnOpen, cnClosing}:
              var fd = curl_waitfd(fd: conn.easy.activeSocket(), events: CURL_WAIT_POLLIN)
              if conn.sends.len > 0 or conn.controls.len > 0:
                fd.events = fd.events or CURL_WAIT_POLLOUT
              fds.add(fd)
          except CatchableError:
            client[].finish(conn, newTransportError(teProtocol, getCurrentExceptionMsg()))
        if conn.mailbox.state != cnFinished:
          if kept != i: swap(active[kept], active[i])
          inc kept
      active.setLen(kept)
      acquire(client.lock)
      # All results and connection events are published by this worker. Notify once
      # per turn, before polling, so consumers can drain data and recheck event
      # deadlines until std/locks supports timed waits.
      broadcast(client.resultCond)
      let done = client.state in {csStopping, csAborting} and
        active.len == 0 and client.commands.len == 0
      release(client.lock)
      if done: break
      discard client.multi.poll(20, fds)
  except CatchableError:
    let error = newTransportError(teInternal, getCurrentExceptionMsg())
    var commands = Deque[Command]()
    acquire(client.lock)
    client.state = csAborting
    swap(commands, client.commands)
    release(client.lock)
    while commands.len > 0:
      let cmd = commands.popFirst()
      client[].completion(cmd, error)
    for conn in active: client[].finish(conn, error)
    acquire(client.lock)
    # Queued connects have shared state but no worker transport yet.
    for mailbox in client.connections:
      if mailbox.state != cnFinished:
        mailbox.terminalError = error
        mailbox.state = cnFinished
    release(client.lock)
  finally:
    acquire(client.lock)
    client.state = csStopped
    # Also release every waiter when a turn exits through the exception path.
    broadcast(client.resultCond)
    release(client.lock)

proc stop(client: var WebSocketClientObj; aborting: static[bool]) =
  # Lifecycle calls belong to the creating thread, after other callers finish.
  if client.closed: return
  acquire(client.lock)
  if client.state in {csRunning, csStopping}:
    when aborting:
      client.state = csAborting
    else:
      client.state = csStopping
  client.multi.wakeup()
  broadcast(client.resultCond)
  release(client.lock)
  joinThread(client.thread)
  reset(client.multi)
  cleanupCurl()
  deinitCond(client.resultCond)
  deinitLock(client.lock)
  client.closed = true

proc newWebSocketClient*(maxConnections = 16; maxCommands = 64; maxEvents = 64;
    defaultTimeoutMs = 60_000; maxMessageBytes = 32 * 1024 * 1024;
    maxQueuedBytes = 32 * 1024 * 1024; closeTimeoutMs = 100;
    bypassProxy = false; proxy: sink string = ""; caInfo: sink string = ""): WebSocketClient =
  ## Start a worker. Nonpositive limits clamp to one.
  ## Call close or abort before releasing the client.
  let client = WebSocketClient(maxConnections: max(1, maxConnections),
    maxCommands: max(1, maxCommands), maxEvents: max(1, maxEvents),
    maxQueuedBytes: max(1, maxQueuedBytes), maxMessageBytes: max(1, maxMessageBytes),
    defaultTimeoutMs: max(1, min(defaultTimeoutMs, cint.high.int)),
    closeTimeoutMs: max(1, min(closeTimeoutMs, cint.high.int)),
    bypassProxy: bypassProxy, proxy: proxy, caInfo: caInfo)
  initCurl()
  initLock(client.lock)
  initCond(client.resultCond)
  try:
    client.multi = initMulti()
    createThread(client.thread, workerMain, addr client[])
  except CatchableError:
    reset(client.multi)
    cleanupCurl()
    deinitCond(client.resultCond)
    deinitLock(client.lock)
    raise
  result = client

proc close*(client: WebSocketClient) =
  ## Stop after bounded close handshakes. Results/events remain drainable after joining.
  if client != nil: client[].stop(false)

proc abort*(client: WebSocketClient) =
  ## Cancel all work and join. Does not wait for peers or consumer queue space.
  if client != nil: client[].stop(true)

proc enqueue(client: var WebSocketClientObj; cmd: sink Command):
    tuple[connectionId: ConnectionId, operationId: OperationId] =
  # Caller holds client.lock.
  if client.state != csRunning:
    raise newException(IOError, "WebSocket worker stopped")
  if client.outstanding >= client.maxCommands:
    raise newException(IOError, "WebSocket command queue is full")
  case cmd.kind
  of wcConnect:
    if client.connections.len >= client.maxConnections:
      raise newException(IOError, "WebSocket connection limit reached; drain terminal events")
    inc client.nextConnection
    cmd.connectionId = ConnectionId(client.nextConnection)
  of wcSend:
    let conn = client.connection(cmd.connectionId)
    assert conn != nil, "WebSocket connection is unknown or drained"
    if conn.state in {cnClosing, cnFinished} or conn.request != srNone:
      raise newException(IOError, "WebSocket connection unavailable")
  inc client.nextOperation
  inc client.outstanding
  cmd.operationId = OperationId(client.nextOperation)
  result = (cmd.connectionId, cmd.operationId)
  if cmd.kind == wcConnect:
    client.connections.add(Mailbox(id: cmd.connectionId))
  client.commands.addLast(cmd)
  client.multi.wakeup()

proc startConnect*(client: WebSocketClient; url: sink string; timeoutMs = 0):
    tuple[connectionId: ConnectionId, operationId: OperationId] =
  ## Submit a connection attempt; correlate its completion by operationId.
  ## Requires a URL without NUL or fragments; curl reports URL errors in the completion.
  assert not client.closed, "WebSocket client is closed"
  assert url.find({'\0', '#'}) < 0, "WebSocket URL contains NUL or fragment"
  acquire(client.lock)
  try:
    result = client[].enqueue(Command(kind: wcConnect, url: url,
      deadline: getMonoTime() + initDuration(milliseconds =
        client[].timeout(timeoutMs))))
  finally:
    release(client.lock)

proc startSend*(client: WebSocketClient; id: ConnectionId;
    message: sink WebSocketMessage; timeoutMs = 0): OperationId =
  ## Submit text or binary data after successful connect completion.
  ## Requires data within maxMessageBytes and UTF-8 for text; refused admission raises IOError.
  assert not client.closed, "WebSocket client is closed"
  assert message.data.len <= client.maxMessageBytes, "WebSocket message exceeds byte limit"
  acquire(client.lock)
  try:
    result = client[].enqueue(Command(kind: wcSend, connectionId: id,
      message: message, deadline: getMonoTime() + initDuration(milliseconds =
        client[].timeout(timeoutMs)))).operationId
  finally:
    release(client.lock)

proc cancel*(client: WebSocketClient; id: ConnectionId) =
  ## Out-of-band cancellation works even when the command queue is full.
  assert not client.closed, "WebSocket client is closed"
  acquire(client.lock)
  let conn = client[].connection(id)
  if conn != nil: conn.request = srCancel
  client.multi.wakeup()
  release(client.lock)

proc startCloseConnection*(client: WebSocketClient; id: ConnectionId) =
  ## Request a bounded close handshake for one connection without waiting.
  assert not client.closed, "WebSocket client is closed"
  acquire(client.lock)
  let conn = client[].connection(id)
  if conn != nil and conn.request == srNone: conn.request = srClose
  client.multi.wakeup()
  release(client.lock)

proc retrieveResult(client: WebSocketClient; item: var WebSocketResult; blocking: bool): bool =
  result = false
  let active = not client.closed
  if active: acquire(client.lock)
  while blocking and client.results.len == 0 and client.state != csStopped:
    wait(client.resultCond, client.lock)
  if client.results.len > 0:
    item = client.results.popFirst()
    dec client.outstanding
    result = true
  if active: release(client.lock)

proc pollForResult*(client: WebSocketClient; item: var WebSocketResult): bool =
  ## Return immediately; true when a completion was retrieved.
  client.retrieveResult(item, false)

proc waitForResult*(client: WebSocketClient; item: var WebSocketResult): bool =
  ## Wait for a completion; false after the worker stops and results drain.
  client.retrieveResult(item, true)

proc retrieveEvent(client: WebSocketClient; id: ConnectionId; item: var WebSocketEvent;
    blocking: bool; timeoutMs: int; required = false): bool =
  result = false
  let deadline = getMonoTime() + initDuration(milliseconds =
    client[].timeout(timeoutMs))
  let active = not client.closed
  if active: acquire(client.lock)
  let conn = client[].connection(id)
  assert not required or conn != nil, "WebSocket connection is unknown or drained"
  if conn != nil:
    while blocking and conn.events.len == 0 and conn.state != cnFinished and
        getMonoTime() < deadline:
      wait(client.resultCond, client.lock)
    if conn.events.len > 0:
      item = conn.events.popFirst()
      conn.queuedBytes -= item.message.data.len
      result = true
    elif conn.state == cnFinished:
      item = WebSocketEvent(connectionId: id, kind: weClosed, error: move conn.terminalError)
      for i in 0..<client.connections.len:
        if client.connections[i].id == id:
          client.connections.delete(i)
          break
      result = true
  if active: release(client.lock)

proc pollForEvent*(client: WebSocketClient; id: ConnectionId; item: var WebSocketEvent): bool =
  ## Return immediately; true when a message or terminal event was retrieved.
  client.retrieveEvent(id, item, false, 0)

proc waitForEvent*(client: WebSocketClient; id: ConnectionId; item: var WebSocketEvent;
    timeoutMs = 0): bool =
  ## Wait for an event; false on timeout, unknown ID or stopped worker without an event.
  client.retrieveEvent(id, item, true, timeoutMs)

proc closeConnection*(client: WebSocketClient; id: ConnectionId) =
  ## Wait for a bounded close handshake and dispose this connection's unread receive data.
  ## Pending operation completions remain available. Requires exclusive receive access.
  assert not client.closed, "WebSocket client is closed"
  acquire(client.lock)
  let conn = client[].connection(id)
  assert conn != nil, "WebSocket connection is unknown or drained"
  if conn.state != cnFinished:
    if conn.request == srNone: conn.request = srClose
    client.multi.wakeup()
  while conn.state != cnFinished:
    wait(client.resultCond, client.lock)
  for i in 0..<client.connections.len:
    if client.connections[i].id == id:
      client.connections.delete(i)
      break
  release(client.lock)

proc clientIsBusy(client: WebSocketClient): bool =
  acquire(client.lock)
  result = client.outstanding != 0
  release(client.lock)

proc connect*(client: WebSocketClient; url: sink string; timeoutMs = 0): WebSocketResult =
  ## Connect and return its transport result. Requires an idle operation pipeline.
  ## A failed attempt is disposed internally; the client can be used for another attempt.
  assert not client.closed, "WebSocket client is closed"
  assert not client.clientIsBusy(), "connect requires an idle client"
  let ids = client.startConnect(url, timeoutMs)
  if not client.waitForResult(result):
    raise newException(IOError, "WebSocket worker stopped before connect completed")
  if result.error.kind != teNone:
    client.closeConnection(ids.connectionId)

proc send*(client: WebSocketClient; id: ConnectionId;
    message: sink WebSocketMessage; timeoutMs = 0): WebSocketResult =
  ## Send text or binary data and return its transport result. Requires an idle pipeline.
  assert not client.closed, "WebSocket client is closed"
  assert not client.clientIsBusy(), "send requires an idle client"
  discard client.startSend(id, message, timeoutMs)
  if not client.waitForResult(result):
    raise newException(IOError, "WebSocket worker stopped before send completed")

proc send*(client: WebSocketClient; id: ConnectionId;
    text: sink string; timeoutMs = 0): WebSocketResult {.inline.} =
  ## Send UTF-8 text and return its transport result.
  client.send(id, WebSocketMessage(kind: wmText, data: text), timeoutMs)

proc receive*(client: WebSocketClient; id: ConnectionId;
    timeoutMs = 0): WebSocketReceiveResult =
  ## Receive text or binary data, terminal status, or a timeout that leaves the connection open.
  ## Requires a known, undrained ID and exclusive receive access to the connection.
  var event: WebSocketEvent
  if client.retrieveEvent(id, event, true, timeoutMs, required = true):
    result = WebSocketReceiveResult(
      kind: if event.kind == weMessage: wrMessage else: wrClosed,
      message: event.message, error: event.error)
  else:
    result = WebSocketReceiveResult(kind: wrTimedOut,
      error: newTransportError(teTimeout, "WebSocket receive timed out"))
