## Persistent WebSockets serviced by one worker, independently of Relay HTTP.
## Requires --mm:atomicArc and --threads:on. Application callbacks stay on consumers.
import std/[base64, deques, locks, monotimes, sha1, strutils, sysrand, times, unicode, uri]
import ./[curl_wrap, transport_errors]
import ./bindings/[curl, websockets]
export transport_errors

type
  TimeoutError* = object of IOError
  ConnectionId* = distinct int64
  OperationId* = distinct int64
  MessageKind* = enum
    wmText, wmBinary
  WebSocketMessage* = object
    kind*: MessageKind
    data*: string
  WebSocketResult* = object
    connectionId*: ConnectionId
    operationId*: OperationId
    error*: TransportError
  WebSocketEventKind* = enum
    weMessage, weClosed
  WebSocketEvent* = object
    connectionId*: ConnectionId
    kind*: WebSocketEventKind
    message*: WebSocketMessage
    error*: TransportError
  CommandKind = enum
    wcConnect, wcSend
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
  # Locks/conditions have identity; destructors must borrow rather than copy them.
  WebSocketServiceObj {.byref.} = object
    lock: Lock
    resultCond: Cond
    thread: Thread[ptr WebSocketServiceObj]
    initialized, threadStarted, started, running, stopping, aborting, closed: bool
    startupError: string
    wakeHandle: CURLM # Only curl_multi_wakeup may touch this handle outside worker.
    commands: Deque[Command]
    results: Deque[WebSocketResult]
    mailboxes: seq[Mailbox]
    nextConnection, nextOperation: int64
    outstanding: int
    maxConnections, maxCommands, maxEvents, maxQueuedBytes: int
    defaultTimeoutMs, maxMessageBytes, closeTimeoutMs: int
    bypassProxy: bool
    proxy, caInfo: string
  WebSocketService* = ref WebSocketServiceObj
  Handshake = object
    expected: string
    accepted: bool
  Connection = ref object
    mailbox: Mailbox
    easy: Easy
    headers: Slist
    handshake: Handshake
    attached, connected, finished, closing, closeSent, peerClosed: bool
    connectCommand: Command
    sends: Deque[Command]
    offset: int
    frameStarted, incomingActive: bool
    incoming: WebSocketMessage
    control: string
    controls: Deque[tuple[data: string, flags: cuint]]
    controlOffset: int
    closeDeadline: MonoTime
  WebSocketObj = object
    service: WebSocketService
    id: ConnectionId
    connected, closed: bool
  WebSocket* = ref WebSocketObj

proc stop(client: ptr WebSocketServiceObj; aborting: bool) {.raises: [].}

proc `=destroy`(client: WebSocketServiceObj) =
  let owner = cast[ptr WebSocketServiceObj](addr client)
  if client.initialized:
    owner.stop(true)
    deinitCond(owner.resultCond)
    deinitLock(owner.lock)
  `=destroy`(client.startupError)
  `=destroy`(owner.commands)
  `=destroy`(owner.results)
  `=destroy`(client.mailboxes)
  `=destroy`(client.proxy)
  `=destroy`(client.caInfo)

proc `=destroy`(client: WebSocketObj) =
  if client.service != nil:
    cast[ptr WebSocketServiceObj](client.service).stop(true)
  `=destroy`(client.service)

proc `==`*(a, b: ConnectionId): bool {.borrow.}
proc `==`*(a, b: OperationId): bool {.borrow.}

proc handle(conn: Connection): CURL {.inline.} =
  cast[CURL](conn.easy.handleKey())

proc timeout(client: ptr WebSocketServiceObj; timeoutMs: int): int =
  if timeoutMs > 0: min(timeoutMs, cint.high.int) else: client.defaultTimeoutMs

proc mailbox(client: ptr WebSocketServiceObj; id: ConnectionId): Mailbox =
  for item in client.mailboxes:
    if item.id == id: return item

proc wake(client: ptr WebSocketServiceObj) =
  client.wakeHandle.wakeup()

proc completion(client: ptr WebSocketServiceObj; cmd: Command; error = TransportError()) =
  acquire(client.lock)
  client.results.addLast(WebSocketResult(connectionId: cmd.connectionId,
    operationId: cmd.operationId, error: error))
  broadcast(client.resultCond)
  release(client.lock)

proc finish(client: ptr WebSocketServiceObj; multi: CURLM; conn: Connection;
    error: TransportError) =
  if not conn.finished:
    conn.finished = true
    if not conn.connected:
      client.completion(conn.connectCommand, error)
    while conn.sends.len > 0:
      client.completion(conn.sends.popFirst(), error)
    if conn.attached:
      discard curl_multi_remove_handle(multi, conn.handle())
      conn.attached = false
    system.reset(conn.easy)
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

proc configure(client: ptr WebSocketServiceObj; multi: CURLM; conn: Connection) =
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
    checkCurl(curl_easy_setopt(conn.handle(), CURLOPT_PROXY, proxy.cstring),
      "CURLOPT_PROXY failed")
  if client.caInfo.len > 0:
    checkCurl(curl_easy_setopt(conn.handle(), CURLOPT_CAINFO, client.caInfo.cstring),
      "CURLOPT_CAINFO failed")
  checkCurl(curl_easy_setopt(conn.handle(), CURLOPT_CONNECT_ONLY, 2.clong),
    "CURLOPT_CONNECT_ONLY failed")
  checkCurl(curl_easy_setopt(conn.handle(), CURLOPT_WS_OPTIONS, CURLWS_NOAUTOPONG),
    "CURLOPT_WS_OPTIONS failed")
  checkMulti(curl_multi_add_handle(multi, conn.handle()), "curl_multi_add_handle failed")
  conn.attached = true

proc publish(client: ptr WebSocketServiceObj; conn: Connection) =
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

proc readFrames(client: ptr WebSocketServiceObj; conn: Connection) =
  var buffer: array[16 * 1024, char]
  var blocked = false
  for turn in 0..<4:
    if not blocked and not conn.peerClosed:
      var received: csize_t
      var meta: ptr curl_ws_frame
      let code = curl_ws_recv(conn.handle(), addr buffer[0], buffer.len.csize_t,
        addr received, addr meta)
      if code == CURLE_AGAIN:
        blocked = true
      else:
        checkCurl(code, "WebSocket receive failed")
        # Copy metadata before another WebSocket call invalidates libcurl's pointer.
        let flags = meta.flags.cuint
        let bytesleft = meta.bytesleft
        if (flags and (CURLWS_TEXT or CURLWS_BINARY)) != 0:
          let kind = if (flags and CURLWS_BINARY) != 0: wmBinary else: wmText
          if conn.incomingActive and conn.incoming.kind != kind:
            raise newException(IOError, "WebSocket fragment type changed")
          let available = client.maxMessageBytes - conn.incoming.data.len
          if bytesleft < 0 or received.uint64 > available.uint64 or
              bytesleft.uint64 > available.uint64 - received.uint64:
            raise newException(IOError, "WebSocket message exceeds byte limit")
          conn.incomingActive = true
          conn.incoming.kind = kind
          let start = conn.incoming.data.len
          conn.incoming.data.setLen(start + received.int)
          if received > 0: copyMem(addr conn.incoming.data[start], addr buffer[0], received.int)
          if bytesleft == 0 and (flags and CURLWS_CONT) == 0:
            if kind == wmText and conn.incoming.data.validateUtf8() >= 0:
              raise newException(IOError, "Invalid UTF-8 WebSocket message")
            client.publish(conn)
            conn.incomingActive = false
        elif (flags and (CURLWS_PING or CURLWS_CLOSE)) != 0:
          let available = 125 - conn.control.len
          if bytesleft < 0 or received.uint64 > available.uint64 or
              bytesleft.uint64 > available.uint64 - received.uint64:
            raise newException(IOError, "Invalid WebSocket control size")
          let start = conn.control.len
          conn.control.setLen(start + received.int)
          if received > 0: copyMem(addr conn.control[start], addr buffer[0], received.int)
          if bytesleft == 0:
            if conn.controls.len >= 8:
              raise newException(IOError, "WebSocket control queue overflow")
            let reply = if (flags and CURLWS_CLOSE) != 0: CURLWS_CLOSE else: CURLWS_PONG
            conn.controls.addLast((move conn.control, reply))
            if reply == CURLWS_CLOSE:
              let payload = conn.controls.peekLast().data
              if payload.len == 1 or (payload.len > 2 and payload[2..^1].validateUtf8() >= 0):
                raise newException(IOError, "Invalid WebSocket close payload")
              if payload.len >= 2:
                let code = ord(payload[0]) * 256 + ord(payload[1])
                if code < 1000 or code >= 5000 or code in [1004, 1005, 1006, 1015] or
                    (code >= 1016 and code < 3000):
                  raise newException(IOError, "Invalid WebSocket close code")
              conn.peerClosed = true
              conn.closing = true
              conn.closeDeadline = getMonoTime() +
                initDuration(milliseconds = client.closeTimeoutMs)
        elif (flags and CURLWS_PONG) == 0:
          raise newException(IOError, "Unsupported WebSocket frame")

proc writeFrame(conn: Connection; data: string; flags: cuint; offset: var int): bool =
  var sent: csize_t
  let buffer = if offset == data.len: nil else: cast[pointer](addr data[offset])
  let code = curl_ws_send(conn.handle(), buffer, (data.len - offset).csize_t,
    addr sent, 0, flags)
  if code != CURLE_AGAIN: checkCurl(code, "WebSocket send failed")
  offset += sent.int
  result = code == CURLE_OK and offset == data.len

proc writeData(conn: Connection; cmd: Command): bool =
  # Explicit partial-frame mode bounds masking/copy work on every worker turn.
  let data = cmd.message.data
  let count = min(16 * 1024, data.len - conn.offset)
  let buffer = if count == 0: nil else: cast[pointer](addr data[conn.offset])
  let kind = if cmd.message.kind == wmText: CURLWS_TEXT else: CURLWS_BINARY
  let flags = if data.len == 0: kind else: kind or CURLWS_OFFSET
  let size = if not conn.frameStarted: data.len.int64 else: 0'i64
  var sent: csize_t
  let code = curl_ws_send(conn.handle(), buffer, count.csize_t, addr sent, size, flags)
  conn.frameStarted = true
  if code != CURLE_AGAIN: checkCurl(code, "WebSocket send failed")
  conn.offset += sent.int
  result = code == CURLE_OK and conn.offset == data.len

proc writeFrames(client: ptr WebSocketServiceObj; conn: Connection) =
  # Finish either partially sent frame before switching between data/control queues.
  if conn.sends.len > 0 and conn.controlOffset == 0 and
      (conn.frameStarted or (not conn.closing and conn.controls.len == 0)):
    let cmd = conn.sends.peekFirst()
    if conn.writeData(cmd):
      client.completion(conn.sends.popFirst())
      conn.offset = 0
      conn.frameStarted = false
  if not conn.frameStarted and conn.controls.len > 0:
    let control = conn.controls.peekFirst()
    if conn.writeFrame(control.data, control.flags, conn.controlOffset):
      if control.flags == CURLWS_CLOSE: conn.closeSent = true
      discard conn.controls.popFirst()
      conn.controlOffset = 0

proc requestClose(client: ptr WebSocketServiceObj; conn: Connection) =
  if not conn.closing:
    conn.closing = true
    conn.closeDeadline = getMonoTime() + initDuration(milliseconds = client.closeTimeoutMs)
    conn.controls.addLast(("", CURLWS_CLOSE))

proc processCommands(client: ptr WebSocketServiceObj; multi: CURLM;
    connections: var seq[Connection]) =
  var commands: Deque[Command]
  acquire(client.lock)
  swap(commands, client.commands)
  release(client.lock)
  while commands.len > 0:
    let cmd = commands.popFirst()
    var conn: Connection
    for item in connections:
      if item.mailbox.id == cmd.connectionId: conn = item
    if cmd.kind == wcConnect:
      acquire(client.lock)
      let box = client.mailbox(cmd.connectionId)
      release(client.lock)
      conn = Connection(mailbox: box, connectCommand: cmd)
      connections.add(conn)
      try:
        if getMonoTime() >= cmd.deadline:
          client.finish(multi, conn, newTransportError(teTimeout, "WebSocket connect timed out"))
        else:
          client.configure(multi, conn)
      except CatchableError:
        client.finish(multi, conn, newTransportError(teNetwork,
          "WebSocket connect failed: " & getCurrentExceptionMsg()))
    elif conn == nil or conn.finished or not conn.connected or conn.closing:
      client.completion(cmd, newTransportError(teCanceled, "WebSocket connection unavailable"))
    else:
      conn.sends.addLast(cmd)

proc upgrades(client: ptr WebSocketServiceObj; multi: CURLM; connections: seq[Connection]) =
  var queued: cint
  var msg = curl_multi_info_read(multi, addr queued)
  while msg != nil:
    if msg.msg == CURLMSG_DONE:
      for conn in connections:
        if not conn.finished and conn.handle() == msg.easy_handle:
          if getMonoTime() >= conn.connectCommand.deadline:
            client.finish(multi, conn, newTransportError(teTimeout, "WebSocket connect timed out"))
          elif msg.data.result != CURLE_OK:
            client.finish(multi, conn, newTransportError(classifyTransportError(msg.data.result),
              "WebSocket connect failed: " & $curl_easy_strerror(msg.data.result),
              msg.data.result.int))
          elif conn.easy.responseCode() != 101 or not conn.handshake.accepted:
            client.finish(multi, conn, newTransportError(teProtocol, "WebSocket upgrade refused"))
          else:
            conn.connected = true
            client.completion(conn.connectCommand)
    msg = curl_multi_info_read(multi, addr queued)

proc workerMain(client: ptr WebSocketServiceObj) {.thread.} =
  var multi: CURLM
  var globalInitialized = false
  var connections: seq[Connection]
  try:
    initGlobal()
    globalInitialized = true
    if curl_version_info(CURLVERSION_FIRST).version_num < 0x080e00:
      raise newException(IOError, "WebSocket client requires libcurl 8.14 or newer")
    multi = curl_multi_init()
    if multi == nil: raise newException(IOError, "curl_multi_init failed")
    acquire(client.lock)
    client.wakeHandle = multi
    client.started = true
    broadcast(client.resultCond)
    release(client.lock)
    var done = false
    while not done:
      client.processCommands(multi, connections)
      var running: cint
      checkMulti(curl_multi_perform(multi, addr running), "curl_multi_perform failed")
      client.upgrades(multi, connections)
      var fds: seq[curl_waitfd]
      acquire(client.lock)
      let stopping = client.stopping
      let aborting = client.aborting
      release(client.lock)
      for conn in connections:
        if not conn.finished:
          acquire(client.lock)
          let canceled = conn.mailbox.cancelRequested
          let closing = conn.mailbox.closeRequested
          release(client.lock)
          try:
            if canceled or aborting:
              client.finish(multi, conn, newTransportError(teCanceled, "WebSocket canceled"))
            elif not conn.connected:
              if stopping:
                client.finish(multi, conn, newTransportError(teCanceled, "WebSocket canceled"))
              elif getMonoTime() >= conn.connectCommand.deadline:
                client.finish(multi, conn,
                  newTransportError(teTimeout, "WebSocket connect timed out"))
            else:
              if closing or stopping: client.requestClose(conn)
              var expired = false
              for cmd in conn.sends:
                if getMonoTime() >= cmd.deadline: expired = true
              if expired:
                client.finish(multi, conn, newTransportError(teTimeout, "WebSocket send timed out"))
              else:
                client.readFrames(conn)
                client.writeFrames(conn)
                if conn.closing and ((conn.peerClosed and conn.closeSent) or
                    getMonoTime() >= conn.closeDeadline):
                  let reason = if conn.peerClosed:
                    "Peer closed the WebSocket connection"
                    else: "WebSocket closed"
                  client.finish(multi, conn, newTransportError(teCanceled, reason))
                else:
                  var fd = curl_waitfd(events: CURL_WAIT_POLLIN)
                  if conn.sends.len > 0 or conn.controls.len > 0:
                    fd.events = fd.events or CURL_WAIT_POLLOUT
                  checkCurl(curl_easy_getinfo(conn.handle(), CURLINFO_ACTIVESOCKET, addr fd.fd),
                    "CURLINFO_ACTIVESOCKET failed")
                  fds.add(fd)
          except CatchableError:
            client.finish(multi, conn, newTransportError(teProtocol, getCurrentExceptionMsg()))
      var active: seq[Connection]
      for conn in connections:
        if not conn.finished: active.add(conn)
      connections = move active
      acquire(client.lock)
      broadcast(client.resultCond) # Timed consumer waits recheck their monotonic deadline.
      done = client.stopping and connections.len == 0 and client.commands.len == 0
      release(client.lock)
      if not done:
        var ready: cint
        let extra = if fds.len == 0: nil else: addr fds[0]
        checkMulti(curl_multi_poll(multi, extra, fds.len.cuint, 20, addr ready),
          "curl_multi_poll failed")
  except CatchableError:
    let error = newTransportError(teInternal, getCurrentExceptionMsg())
    for conn in connections: client.finish(multi, conn, error)
    acquire(client.lock)
    client.startupError = error.message
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
    client.wakeHandle = nil
    release(client.lock)
    if multi != nil: discard curl_multi_cleanup(multi)
    if globalInitialized: cleanupGlobal()
    acquire(client.lock)
    client.running = false
    client.started = true
    broadcast(client.resultCond)
    release(client.lock)

proc stop(client: ptr WebSocketServiceObj; aborting: bool) =
  # Lifecycle calls belong to the creating thread, matching HttpClient's receiver contract.
  acquire(client.lock)
  let join = not client.closed
  if join:
    client.stopping = true
    client.aborting = aborting
    client.wake()
    broadcast(client.resultCond)
  release(client.lock)
  if join:
    if client.threadStarted: joinThread(client.thread)
    acquire(client.lock)
    client.closed = true
    broadcast(client.resultCond)
    release(client.lock)

proc newWebSocketService*(maxConnections = 16; maxCommands = 64; maxEvents = 64;
    defaultTimeoutMs = 60_000; maxMessageBytes = 32 * 1024 * 1024;
    maxQueuedBytes = 32 * 1024 * 1024; closeTimeoutMs = 100;
    bypassProxy = false; proxy = ""; caInfo = ""): WebSocketService =
  ## One worker owns all curl state. Nonpositive limits clamp to one, like newHttpClient.
  when not defined(gcAtomicArc):
    {.error: "Relay WebSockets require --mm:atomicArc".}
  let client = WebSocketService(maxConnections: max(1, maxConnections),
    maxCommands: max(1, maxCommands), maxEvents: max(1, maxEvents),
    maxQueuedBytes: max(1, maxQueuedBytes), maxMessageBytes: max(1, maxMessageBytes),
    defaultTimeoutMs: max(1, min(defaultTimeoutMs, cint.high.int)),
    closeTimeoutMs: max(1, min(closeTimeoutMs, cint.high.int)),
    bypassProxy: bypassProxy, proxy: proxy, caInfo: caInfo, running: true)
  initLock(client.lock)
  initCond(client.resultCond)
  client.initialized = true
  createThread(client.thread, workerMain, cast[ptr WebSocketServiceObj](client))
  client.threadStarted = true
  acquire(client.lock)
  while not client.started: wait(client.resultCond, client.lock)
  let error = client.startupError
  release(client.lock)
  if error.len > 0:
    cast[ptr WebSocketServiceObj](client).stop(true)
    raise newException(IOError, error)
  result = client

proc close*(client: WebSocketService) =
  ## Stop after bounded close handshakes. Results/events remain drainable after joining.
  if client != nil: cast[ptr WebSocketServiceObj](client).stop(false)

proc abort*(client: WebSocketService) =
  ## Cancel all work and join. Does not wait for peers or consumer queue space.
  if client != nil: cast[ptr WebSocketServiceObj](client).stop(true)

proc validateUrl(url: string) =
  let u = parseUri(url)
  if u.scheme notin ["ws", "wss"] or u.hostname.len == 0 or
      u.username.len > 0 or u.password.len > 0 or u.anchor.len > 0 or
      url.find({'\0'..' ', '\x7f'}) >= 0:
    raise newException(ValueError, "Invalid WebSocket URL")

proc checkAdmission(client: WebSocketService) =
  if client.closed or client.stopping or not client.running:
    raise newException(IOError, "WebSocket service is closed")
  if client.outstanding >= client.maxCommands:
    raise newException(IOError, "WebSocket command queue is full")
  if client.nextOperation == int64.high:
    raise newException(IOError, "WebSocket operation IDs exhausted")

proc startConnect*(client: WebSocketService; url: sink string; timeoutMs = 0):
    tuple[connectionId: ConnectionId, operationId: OperationId] =
  validateUrl(url)
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
        cast[ptr WebSocketServiceObj](client).timeout(timeoutMs))))
    cast[ptr WebSocketServiceObj](client).wake()
  finally:
    release(client.lock)

proc startSend*(client: WebSocketService; id: ConnectionId;
    message: sink WebSocketMessage; timeoutMs = 0): OperationId =
  if message.data.len > client.maxMessageBytes or
      (message.kind == wmText and message.data.validateUtf8() >= 0):
    raise newException(ValueError, "Invalid WebSocket text or message size")
  acquire(client.lock)
  try:
    client.checkAdmission()
    let box = cast[ptr WebSocketServiceObj](client).mailbox(id)
    if box == nil or box.terminal or box.cancelRequested or box.closeRequested:
      raise newException(IOError, "WebSocket connection unavailable")
    inc client.nextOperation
    inc client.outstanding
    result = OperationId(client.nextOperation)
    client.commands.addLast(Command(kind: wcSend, connectionId: id, operationId: result,
      message: message, deadline: getMonoTime() + initDuration(milliseconds =
        cast[ptr WebSocketServiceObj](client).timeout(timeoutMs))))
    cast[ptr WebSocketServiceObj](client).wake()
  finally:
    release(client.lock)

proc cancel*(client: WebSocketService; id: ConnectionId) =
  ## Out-of-band cancellation works even when the command queue is full.
  acquire(client.lock)
  let box = cast[ptr WebSocketServiceObj](client).mailbox(id)
  if box != nil: box.cancelRequested = true
  cast[ptr WebSocketServiceObj](client).wake()
  release(client.lock)

proc closeConnection*(client: WebSocketService; id: ConnectionId) =
  acquire(client.lock)
  let box = cast[ptr WebSocketServiceObj](client).mailbox(id)
  if box != nil: box.closeRequested = true
  cast[ptr WebSocketServiceObj](client).wake()
  release(client.lock)

proc retrieveResult(client: WebSocketService; item: var WebSocketResult; blocking: bool): bool =
  acquire(client.lock)
  if blocking:
    while client.results.len == 0 and client.running: wait(client.resultCond, client.lock)
  if client.results.len > 0:
    item = client.results.popFirst()
    dec client.outstanding
    result = true
  release(client.lock)

proc pollForResult*(client: WebSocketService; item: var WebSocketResult): bool =
  client.retrieveResult(item, false)

proc waitForResult*(client: WebSocketService; item: var WebSocketResult): bool =
  client.retrieveResult(item, true)

proc retrieveEvent(client: WebSocketService; id: ConnectionId; item: var WebSocketEvent;
    blocking: bool; timeoutMs: int): bool =
  let deadline = getMonoTime() + initDuration(milliseconds =
    cast[ptr WebSocketServiceObj](client).timeout(timeoutMs))
  acquire(client.lock)
  try:
    let box = cast[ptr WebSocketServiceObj](client).mailbox(id)
    if box != nil:
      while blocking and box.events.len == 0 and not box.terminal and client.running and
          getMonoTime() < deadline:
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
  finally:
    release(client.lock)

proc pollForEvent*(client: WebSocketService; id: ConnectionId; item: var WebSocketEvent): bool =
  client.retrieveEvent(id, item, false, 0)

proc waitForEvent*(client: WebSocketService; id: ConnectionId; item: var WebSocketEvent;
    timeoutMs = 0): bool =
  ## False on deadline expiry, forgotten ID or stopped worker without an event.
  client.retrieveEvent(id, item, true, timeoutMs)

proc raiseTransport(error: TransportError) =
  if error.kind == teTimeout: raise newException(TimeoutError, error.message)
  if error.kind != teNone: raise newException(IOError, error.message)

proc newWebSocket*(defaultTimeoutMs = 60_000; maxMessageBytes = 32 * 1024 * 1024;
    bypassProxy = false): WebSocket =
  ## Single-connection synchronous convenience owner. Use a service to multiplex.
  WebSocket(service: newWebSocketService(maxConnections = 1,
    defaultTimeoutMs = defaultTimeoutMs, maxMessageBytes = maxMessageBytes,
    bypassProxy = bypassProxy))

proc checkOpen(client: WebSocket; connected = true) =
  if client == nil or client.closed:
    raise newException(IOError, "WebSocket client is closed")
  if connected and not client.connected:
    raise newException(IOError, "WebSocket client is not connected")

proc close*(client: WebSocket) =
  if client != nil and not client.closed:
    client.closed = true
    client.connected = false
    client.service.close()

proc connect*(client: WebSocket; url: string; timeoutMs = 0) =
  client.checkOpen(false)
  if client.connected: raise newException(ValueError, "WebSocket client is already connected")
  validateUrl(url)
  try:
    let ids = client.service.startConnect(url, timeoutMs)
    client.id = ids.connectionId
    var completion: WebSocketResult
    if not client.service.waitForResult(completion):
      raise newException(IOError, "WebSocket worker stopped")
    raiseTransport(completion.error)
    client.connected = true
  except CatchableError:
    client.close()
    raise

proc send*(client: WebSocket; text: string; timeoutMs = 0) =
  client.checkOpen()
  # Caller input errors leave the connection usable.
  if text.len > client.service.maxMessageBytes or text.validateUtf8() >= 0:
    raise newException(ValueError, "Invalid WebSocket text or message size")
  try:
    discard client.service.startSend(client.id,
      WebSocketMessage(kind: wmText, data: text), timeoutMs)
    var completion: WebSocketResult
    if not client.service.waitForResult(completion):
      raise newException(IOError, "WebSocket worker stopped")
    raiseTransport(completion.error)
  except CatchableError:
    client.close()
    raise

proc receive*(client: WebSocket; timeoutMs = 0): string =
  client.checkOpen()
  try:
    var event: WebSocketEvent
    if not client.service.waitForEvent(client.id, event, timeoutMs):
      raise newException(TimeoutError, "WebSocket receive timed out")
    if event.kind == weClosed: raiseTransport(event.error)
    if event.message.kind != wmText:
      raise newException(IOError, "WebSocket requires text messages")
    result = move event.message.data
  except CatchableError:
    client.close()
    raise
