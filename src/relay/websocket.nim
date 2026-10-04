## Blocking text WebSockets and a worker for multiple text/binary connections.
## Requires --threads:on --mm:atomicArc and WebSocket-enabled libcurl 8.14+.
## Call close or abort before releasing an owner; shutdown belongs to its creating thread.
import std/[base64, deques, locks, monotimes, sha1, strutils, sysrand, times, unicode, uri]
import ./[curl_wrap, transport_errors]
import ./bindings/curl
export transport_errors

type
  TimeoutError* = object of IOError ## Deadline expiry in the blocking text API.
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
  Mailbox = ref object
    id: ConnectionId
    events: Deque[WebSocketEvent]
    bytes: int
    terminal: bool
    terminalError: TransportError
    cancelRequested, closeRequested: bool
  WebSocketClientObj = object
    lock: Lock
    resultCond: Cond
    thread: Thread[ptr WebSocketClientObj]
    state: ClientState
    closed: bool # Owner-only: worker joined and synchronization released.
    multi: Multi
    commands: Deque[Command]
    results: Deque[WebSocketResult]
    mailboxes: seq[Mailbox]
    proxy, caInfo: string
    nextConnection, nextOperation: int64
    outstanding: int # Accepted operations, including results awaiting consumption.
    maxConnections, maxCommands, maxEvents, maxQueuedBytes: int
    defaultTimeoutMs, maxMessageBytes, closeTimeoutMs: int
    bypassProxy: bool
  WebSocketClient* = ref WebSocketClientObj ## One worker for multiple connections.
  Handshake = object
    expected: string
    accepted: bool
  ConnectionState = enum
    cnConnecting, cnOpen, cnClosing, cnFinished
  ConnectionFlag = enum
    cfAttached, cfCloseSent, cfPeerClosed, cfFrameStarted, cfIncomingActive
  Connection = ref object
    mailbox: Mailbox
    easy: Easy
    headers: Slist
    handshake: Handshake
    state: ConnectionState
    flags: set[ConnectionFlag]
    connectCommand: Command
    sends: Deque[Command]
    offset: int
    incoming: WebSocketMessage
    control: string
    controls: Deque[tuple[data: string, flags: cuint]]
    controlOffset: int
    closeDeadline: MonoTime
  WebSocketObj = object
    service: WebSocketClient
    id: ConnectionId
    connected, closed: bool
  WebSocket* = ref WebSocketObj ## Blocking text connection.

proc `==`*(a, b: ConnectionId): bool {.borrow.}
proc `==`*(a, b: OperationId): bool {.borrow.}

proc timeout(client: WebSocketClientObj; timeoutMs: int): int =
  if timeoutMs > 0: min(timeoutMs, cint.high.int) else: client.defaultTimeoutMs

proc mailbox(client: WebSocketClientObj; id: ConnectionId): Mailbox =
  for item in client.mailboxes:
    if item.id == id: return item

proc completion(client: var WebSocketClientObj; cmd: Command; error = TransportError()) =
  acquire(client.lock)
  client.results.addLast(WebSocketResult(connectionId: cmd.connectionId,
    operationId: cmd.operationId, error: error))
  broadcast(client.resultCond)
  release(client.lock)

proc finish(client: var WebSocketClientObj; conn: Connection;
    error: TransportError) =
  if conn.state == cnFinished: return
  let previous = conn.state
  conn.state = cnFinished
  if previous == cnConnecting:
    client.completion(conn.connectCommand, error)
  while conn.sends.len > 0:
    client.completion(conn.sends.popFirst(), error)
  if cfAttached in conn.flags:
    try:
      client.multi.removeHandle(conn.easy)
    except IOError:
      discard
    conn.flags.excl(cfAttached)
  reset(conn.easy)
  reset(conn.headers)
  acquire(client.lock)
  conn.mailbox.terminal = true
  conn.mailbox.terminalError = error
  broadcast(client.resultCond)
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
        conn.incoming.data.len > client.maxQueuedBytes - conn.mailbox.bytes:
      raise newException(IOError, "WebSocket event queue overflow")
    conn.mailbox.bytes += conn.incoming.data.len
    conn.mailbox.events.addLast(WebSocketEvent(connectionId: conn.mailbox.id,
      kind: weMessage, message: move conn.incoming))
    broadcast(client.resultCond)
  finally:
    release(client.lock)

proc readFrames(client: var WebSocketClientObj; conn: Connection) =
  var buffer: array[16 * 1024, char]
  for turn in 0..<4:
    if cfPeerClosed in conn.flags: break
    var received: csize_t
    var frame: tuple[flags: cuint, bytesLeft: curl_off_t]
    if not conn.easy.recvFrame(addr buffer[0], buffer.len.csize_t, received, frame): break
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
        if conn.controls.len >= 8:
          raise newException(IOError, "WebSocket control queue overflow")
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
          conn.state = cnClosing
          conn.closeDeadline = getMonoTime() +
            initDuration(milliseconds = client.closeTimeoutMs)
        conn.controls.addLast((move conn.control, reply))
    elif (flags and CURLWS_PONG) == 0:
      raise newException(IOError, "Unsupported WebSocket frame")

proc writeFrame(conn: Connection; data: string; flags: cuint; offset: var int): bool =
  var sent: csize_t
  let buffer = if offset == data.len: nil else: cast[pointer](addr data[offset])
  let ready = conn.easy.sendFrame(buffer, (data.len - offset).csize_t, sent, 0, flags)
  offset += sent.int
  result = ready and offset == data.len

proc writeData(conn: Connection; cmd: Command): bool =
  # Explicit partial-frame mode bounds masking/copy work on every worker turn.
  let data = cmd.message.data
  let count = min(16 * 1024, data.len - conn.offset)
  let buffer = if count == 0: nil else: cast[pointer](addr data[conn.offset])
  let kind = if cmd.message.kind == wmText: CURLWS_TEXT else: CURLWS_BINARY
  let flags = if data.len == 0: kind else: kind or CURLWS_OFFSET
  let size = if cfFrameStarted notin conn.flags: data.len.int64 else: 0'i64
  var sent: csize_t
  let ready = conn.easy.sendFrame(buffer, count.csize_t, sent, size, flags)
  conn.flags.incl(cfFrameStarted)
  conn.offset += sent.int
  result = ready and conn.offset == data.len

proc writeFrames(client: var WebSocketClientObj; conn: Connection) =
  # Finish either partially sent frame before switching between data/control queues.
  if conn.sends.len > 0 and conn.controlOffset == 0 and
      (cfFrameStarted in conn.flags or (conn.state != cnClosing and conn.controls.len == 0)):
    let cmd = conn.sends.peekFirst()
    if conn.writeData(cmd):
      client.completion(conn.sends.popFirst())
      conn.offset = 0
      conn.flags.excl(cfFrameStarted)
  if cfFrameStarted notin conn.flags and conn.controls.len > 0:
    let control = conn.controls.peekFirst()
    if conn.writeFrame(control.data, control.flags, conn.controlOffset):
      if control.flags == CURLWS_CLOSE: conn.flags.incl(cfCloseSent)
      discard conn.controls.popFirst()
      conn.controlOffset = 0

proc requestClose(client: WebSocketClientObj; conn: Connection) =
  if conn.state == cnOpen:
    conn.state = cnClosing
    conn.closeDeadline = getMonoTime() + initDuration(milliseconds = client.closeTimeoutMs)
    conn.controls.addLast(("", CURLWS_CLOSE))

proc processCommands(client: var WebSocketClientObj; connections: var seq[Connection]) =
  var commands: Deque[Command]
  acquire(client.lock)
  swap(commands, client.commands)
  release(client.lock)
  while commands.len > 0:
    let cmd = commands.popFirst()
    case cmd.kind
    of wcConnect:
      acquire(client.lock)
      let box = client.mailbox(cmd.connectionId)
      release(client.lock)
      let conn = Connection(mailbox: box, connectCommand: cmd)
      connections.add(conn)
      if getMonoTime() >= cmd.deadline:
        client.finish(conn, newTransportError(teTimeout, "WebSocket connect timed out"))
      else:
        try:
          client.configure(conn)
        except CatchableError:
          client.finish(conn, newTransportError(teNetwork,
            "WebSocket connect failed: " & getCurrentExceptionMsg()))
    of wcSend:
      var conn: Connection
      for item in connections:
        if item.mailbox.id == cmd.connectionId:
          conn = item
          break
      if conn == nil or conn.state != cnOpen:
        client.completion(cmd, newTransportError(teCanceled, "WebSocket connection unavailable"))
      else:
        conn.sends.addLast(cmd)

proc upgrades(client: var WebSocketClientObj; connections: seq[Connection]) =
  var queued: int
  var msg: CURLMsg
  while client.multi.tryInfoRead(msg, queued):
    if msg.msg == CURLMSG_DONE:
      for conn in connections:
        if conn.state != cnFinished and conn.easy.handleKey() == msg.handleKey():
          if getMonoTime() >= conn.connectCommand.deadline:
            client.finish(conn, newTransportError(teTimeout, "WebSocket connect timed out"))
          elif msg.data.result != CURLE_OK:
            client.finish(conn, newTransportError(classifyTransportError(msg.data.result),
              "WebSocket connect failed: " & $curl_easy_strerror(msg.data.result),
              msg.data.result.int))
          elif conn.easy.responseCode() != 101 or not conn.handshake.accepted:
            client.finish(conn, newTransportError(teProtocol, "WebSocket upgrade refused"))
          else:
            conn.state = cnOpen
            client.completion(conn.connectCommand)
          break

proc serviceConnection(client: var WebSocketClientObj; conn: Connection;
    state: ClientState) =
  acquire(client.lock)
  let canceled = conn.mailbox.cancelRequested
  let closing = conn.mailbox.closeRequested
  release(client.lock)
  if canceled or state == csAborting or
      (state == csStopping and conn.state == cnConnecting):
    client.finish(conn, newTransportError(teCanceled, "WebSocket canceled"))
  else:
    case conn.state
    of cnConnecting:
      if getMonoTime() >= conn.connectCommand.deadline:
        client.finish(conn, newTransportError(teTimeout, "WebSocket connect timed out"))
    of cnOpen, cnClosing:
      if closing or state == csStopping: client.requestClose(conn)
      var expired = false
      let now = getMonoTime()
      for cmd in conn.sends:
        if now >= cmd.deadline:
          expired = true
          break
      if expired:
        client.finish(conn, newTransportError(teTimeout, "WebSocket send timed out"))
      else:
        client.readFrames(conn)
        client.writeFrames(conn)
        if conn.state == cnClosing and ({cfPeerClosed, cfCloseSent} <= conn.flags or
            getMonoTime() >= conn.closeDeadline):
          let reason = if cfPeerClosed in conn.flags:
            "Peer closed the WebSocket connection"
            else: "WebSocket closed"
          client.finish(conn, newTransportError(teCanceled, reason))
    of cnFinished:
      discard

proc workerMain(client: ptr WebSocketClientObj) {.thread.} =
  var connections: seq[Connection] = @[]
  var fds: seq[curl_waitfd] = @[]
  try:
    while true:
      client[].processCommands(connections)
      discard client.multi.perform()
      client[].upgrades(connections)
      fds.setLen(0)
      acquire(client.lock)
      let state = client.state
      release(client.lock)
      var kept = 0
      for i in 0..<connections.len:
        let conn = connections[i]
        if conn.state != cnFinished:
          try:
            client[].serviceConnection(conn, state)
            if conn.state in {cnOpen, cnClosing}:
              var fd = curl_waitfd(fd: conn.easy.activeSocket(), events: CURL_WAIT_POLLIN)
              if conn.sends.len > 0 or conn.controls.len > 0:
                fd.events = fd.events or CURL_WAIT_POLLOUT
              fds.add(fd)
          except CatchableError:
            client[].finish(conn, newTransportError(teProtocol, getCurrentExceptionMsg()))
        if conn.state != cnFinished:
          if kept != i: swap(connections[kept], connections[i])
          inc kept
      connections.setLen(kept)
      acquire(client.lock)
      broadcast(client.resultCond) # Timed consumer waits recheck their monotonic deadline.
      let done = client.state in {csStopping, csAborting} and
        connections.len == 0 and client.commands.len == 0
      release(client.lock)
      if done: break
      discard client.multi.poll(20, fds)
  except CatchableError:
    let error = newTransportError(teInternal, getCurrentExceptionMsg())
    for conn in connections: client[].finish(conn, error)
    acquire(client.lock)
    client.state = csAborting
    while client.commands.len > 0:
      let cmd = client.commands.popFirst()
      client.results.addLast(WebSocketResult(connectionId: cmd.connectionId,
        operationId: cmd.operationId, error: error))
    for box in client.mailboxes:
      if not box.terminal:
        box.terminal = true
        box.terminalError = error
    release(client.lock)
  finally:
    acquire(client.lock)
    client.state = csStopped
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
    bypassProxy = false; proxy = ""; caInfo = ""): WebSocketClient =
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
  except Exception:
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

proc validateUrl(url: string) =
  let u = parseUri(url)
  if u.scheme notin ["ws", "wss"] or u.hostname.len == 0 or
      u.username.len > 0 or u.password.len > 0 or u.anchor.len > 0 or
      url.find({'\0'..' ', '\x7f'}) >= 0:
    raise newException(ValueError, "Invalid WebSocket URL")

proc checkAdmission(client: WebSocketClient) =
  if client.state != csRunning:
    raise newException(IOError, "WebSocket client is closed")
  if client.outstanding >= client.maxCommands:
    raise newException(IOError, "WebSocket command queue is full")
  if client.nextOperation == int64.high:
    raise newException(IOError, "WebSocket operation IDs exhausted")

proc startConnect*(client: WebSocketClient; url: sink string; timeoutMs = 0):
    tuple[connectionId: ConnectionId, operationId: OperationId] =
  ## Submit a connection attempt; correlate its completion by operationId.
  validateUrl(url)
  if client.closed:
    raise newException(IOError, "WebSocket client is closed")
  acquire(client.lock)
  try:
    client.checkAdmission()
    if client.mailboxes.len >= client.maxConnections or client.nextConnection == int64.high:
      raise newException(IOError, "WebSocket connection limit reached; drain terminal events")
    inc client.nextConnection
    inc client.nextOperation
    inc client.outstanding
    result = (ConnectionId(client.nextConnection), OperationId(client.nextOperation))
    client.mailboxes.add(Mailbox(id: result.connectionId))
    client.commands.addLast(Command(kind: wcConnect, connectionId: result.connectionId,
      operationId: result.operationId, url: url,
      deadline: getMonoTime() + initDuration(milliseconds =
        client[].timeout(timeoutMs))))
    client.multi.wakeup()
  finally:
    release(client.lock)

proc startSend*(client: WebSocketClient; id: ConnectionId;
    message: sink WebSocketMessage; timeoutMs = 0): OperationId =
  ## Submit text or binary data after successful connect completion.
  ## Invalid text/size raises ValueError; refused admission raises IOError.
  if message.data.len > client.maxMessageBytes or
      (message.kind == wmText and message.data.validateUtf8() >= 0):
    raise newException(ValueError, "Invalid WebSocket text or message size")
  if client.closed:
    raise newException(IOError, "WebSocket client is closed")
  acquire(client.lock)
  try:
    client.checkAdmission()
    let box = client[].mailbox(id)
    if box == nil or box.terminal or box.cancelRequested or box.closeRequested:
      raise newException(IOError, "WebSocket connection unavailable")
    inc client.nextOperation
    inc client.outstanding
    result = OperationId(client.nextOperation)
    client.commands.addLast(Command(kind: wcSend, connectionId: id, operationId: result,
      message: message, deadline: getMonoTime() + initDuration(milliseconds =
        client[].timeout(timeoutMs))))
    client.multi.wakeup()
  finally:
    release(client.lock)

proc cancel*(client: WebSocketClient; id: ConnectionId) =
  ## Out-of-band cancellation works even when the command queue is full.
  if client.closed: return
  acquire(client.lock)
  let box = client[].mailbox(id)
  if box != nil: box.cancelRequested = true
  client.multi.wakeup()
  release(client.lock)

proc closeConnection*(client: WebSocketClient; id: ConnectionId) =
  ## Request a bounded close handshake for one connection without waiting.
  if client.closed: return
  acquire(client.lock)
  let box = client[].mailbox(id)
  if box != nil: box.closeRequested = true
  client.multi.wakeup()
  release(client.lock)

proc retrieveResult(client: WebSocketClient; item: var WebSocketResult; blocking: bool): bool =
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
    blocking: bool; timeoutMs: int): bool =
  let deadline = getMonoTime() + initDuration(milliseconds =
    client[].timeout(timeoutMs))
  let active = not client.closed
  if active: acquire(client.lock)
  let box = client[].mailbox(id)
  if box != nil:
    while blocking and box.events.len == 0 and not box.terminal and
        client.state != csStopped and getMonoTime() < deadline:
      wait(client.resultCond, client.lock)
    if box.events.len > 0:
      item = box.events.popFirst()
      box.bytes -= item.message.data.len
      result = true
    elif box.terminal:
      item = WebSocketEvent(connectionId: id, kind: weClosed, error: box.terminalError)
      for i in 0..<client.mailboxes.len:
        if client.mailboxes[i].id == id:
          client.mailboxes.delete(i)
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

proc raiseTransport(error: TransportError) =
  if error.kind == teTimeout: raise newException(TimeoutError, error.message)
  if error.kind != teNone: raise newException(IOError, error.message)

proc newWebSocket*(defaultTimeoutMs = 60_000; maxMessageBytes = 32 * 1024 * 1024;
    bypassProxy = false): WebSocket =
  ## Create a blocking text connection. Call close before releasing it.
  WebSocket(service: newWebSocketClient(maxConnections = 1,
    defaultTimeoutMs = defaultTimeoutMs, maxMessageBytes = maxMessageBytes,
    bypassProxy = bypassProxy))

proc close*(client: WebSocket) =
  ## Close the connection and join its worker. Repeated calls are safe.
  if client != nil and not client.closed:
    client.closed = true
    client.connected = false
    client.service.close()

proc connect*(client: WebSocket; url: string; timeoutMs = 0) =
  ## Open a ws/wss connection and propagate connection errors.
  assert not client.closed, "WebSocket client is closed"
  if client.connected: raise newException(ValueError, "WebSocket client is already connected")
  let ids = client.service.startConnect(url, timeoutMs)
  client.id = ids.connectionId
  var completion: WebSocketResult
  if not client.service.waitForResult(completion):
    raise newException(IOError, "WebSocket worker stopped")
  raiseTransport(completion.error)
  client.connected = true

proc send*(client: WebSocket; text: string; timeoutMs = 0) =
  ## Send UTF-8 text and wait for completion.
  assert client.connected, "WebSocket client is not connected"
  discard client.service.startSend(client.id,
    WebSocketMessage(kind: wmText, data: text), timeoutMs)
  var completion: WebSocketResult
  if not client.service.waitForResult(completion):
    raise newException(IOError, "WebSocket worker stopped")
  raiseTransport(completion.error)

proc receive*(client: WebSocket; timeoutMs = 0): string =
  ## Wait for UTF-8 text; timeout leaves the connection open.
  assert client.connected, "WebSocket client is not connected"
  var event: WebSocketEvent
  if not client.service.waitForEvent(client.id, event, timeoutMs):
    raise newException(TimeoutError, "WebSocket receive timed out")
  if event.kind == weClosed:
    client.connected = false
    raiseTransport(event.error)
  if event.message.kind != wmText:
    raise newException(IOError, "WebSocket requires text messages")
  result = move event.message.data
