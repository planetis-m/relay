## Bounded independent wire fixtures; no external URLs or provider calls.
import std/[assertions, monotimes, os, strutils, times]
import relay/http
import relay/websocket

proc resultFor(service: WebSocketClient; operation: OperationId): WebSocketResult =
  doAssert service.waitForResult(result)
  doAssert result.operationId == operation

proc eventFor(service: WebSocketClient; id: ConnectionId): WebSocketEvent =
  doAssert service.waitForEvent(id, result, 1500)

proc opened(service: WebSocketClient; url: string): ConnectionId =
  let ids = service.startConnect(url)
  doAssert service.resultFor(ids.operationId).error.kind == teNone
  result = ids.connectionId

proc text(service: WebSocketClient; id: ConnectionId; data: string): OperationId =
  service.startSend(id, WebSocketMessage(kind: wmText, data: data))

type Waiter = object
  service: pointer
  id: ConnectionId
  received: bool
  event: WebSocketEvent

proc awaitEvent(waiter: ptr Waiter) {.thread.} =
  let service = cast[WebSocketClient](waiter.service)
  waiter.received = service.waitForEvent(waiter.id, waiter.event, 1500)

proc main() =
  let url = paramStr(1)
  let mode = paramStr(2)
  let service = newWebSocketClient(maxConnections = 2, maxCommands = 2,
    maxEvents = 2, maxQueuedBytes = if mode == "bytes": 8 else: 32 * 1024 * 1024,
    defaultTimeoutMs = 1500, bypassProxy = true, caInfo = paramStr(3))
  try:
    if mode == "text-client":
      let client = newWebSocket(defaultTimeoutMs = 1500, maxMessageBytes = 8,
        bypassProxy = true)
      try:
        for invalid in ["http://example.com/", url & "#fragment"]:
          doAssertRaises ValueError: client.connect(invalid)
        client.connect(url)
        doAssertRaises ValueError: client.connect(url)
        for invalid in ["\xff", repeat('x', 9)]:
          doAssertRaises ValueError: client.send(invalid)
        client.send("echo")
        doAssert client.receive() == "echo"
        doAssertRaises TimeoutError: discard client.receive(timeoutMs = 30)
        client.send("alive")
        doAssert client.receive() == "alive"
      finally:
        client.close()
    elif mode == "text-failure":
      let failed = newWebSocket(defaultTimeoutMs = 1500, bypassProxy = true)
      try:
        doAssertRaises IOError: failed.connect(url & "bad")
        # Failed connect leaves the owner open for caller-managed cleanup.
        doAssertRaises ValueError: failed.connect("http://example.com/")
      finally:
        failed.close()
      let peer = newWebSocket(defaultTimeoutMs = 1500, bypassProxy = true)
      try:
        peer.connect(url & "close")
        sleep(80)
        doAssertRaises IOError: peer.send("hello")
        try:
          discard peer.receive()
          doAssert false, "expected peer closure"
        except IOError as error:
          doAssert error.msg == "Peer closed the WebSocket connection"
        when not defined(danger):
          doAssertRaises AssertionDefect: peer.send("disconnected")
        doAssertRaises ValueError: peer.connect("http://example.com/")
      finally:
        peer.close()
    elif mode.startsWith("tls"):
      let ids = service.startConnect(url)
      let response = service.resultFor(ids.operationId)
      if mode == "tls-accept":
        doAssert response.error.kind == teNone
        let send = service.text(ids.connectionId, "secure echo")
        doAssert service.resultFor(send).error.kind == teNone
        doAssert service.eventFor(ids.connectionId).message.data == "secure echo"
      else:
        doAssert response.error.kind == teTls, response.error.message
    elif mode == "cancel-connect":
      let ids = service.startConnect(url & "stall")
      sleep(40)
      service.cancel(ids.connectionId)
      doAssert service.resultFor(ids.operationId).error.kind == teCanceled
      doAssert service.eventFor(ids.connectionId).kind == weClosed
      let id = service.opened(url)
      doAssert service.resultFor(service.text(id, "recovered")).error.kind == teNone
      doAssert service.eventFor(id).message.data == "recovered"
    elif mode == "failure":
      let bad = service.startConnect(url & "bad")
      doAssert service.resultFor(bad.operationId).error.kind != teNone
      doAssert service.eventFor(bad.connectionId).kind == weClosed
      let id = service.opened(url)
      doAssert service.resultFor(service.text(id, "healthy")).error.kind == teNone
      doAssert service.eventFor(id).message.data == "healthy"
    elif mode in ["pressure", "bytes"]:
      let slow = service.opened(url & "flood")
      let fast = service.opened(url)
      sleep(80)
      # Full mailbox preserves accepted messages, then a reserved terminal error.
      for i in 0..<(if mode == "bytes": 1 else: 2):
        doAssert service.eventFor(slow).message.data == "flood" & $i
      let terminal = service.eventFor(slow)
      doAssert terminal.kind == weClosed
      doAssert terminal.error.message.contains("overflow")
      let a = service.text(fast, "a")
      let b = service.text(fast, "b")
      doAssertRaises IOError: discard service.text(fast, "over capacity")
      doAssert service.resultFor(a).error.kind == teNone
      doAssert service.resultFor(b).error.kind == teNone
      doAssert service.eventFor(fast).message.data == "a"
      doAssert service.eventFor(fast).message.data == "b"
    elif mode in ["duplex", "partial"]:
      let id = service.opened(url & mode)
      let data = repeat('x', if mode == "partial": 4 * 1024 * 1024 else: 200_000)
      let operation = service.text(id, data)
      if mode == "duplex":
        doAssert service.eventFor(id).message.data == repeat('i', 200_000)
      doAssert service.resultFor(operation).error.kind == teNone
      doAssert service.eventFor(id).message.data == data
    elif mode == "idle-close":
      let id = service.opened(url & "no-close")
      let started = getMonoTime()
      service.closeConnection(id)
      doAssert service.eventFor(id).kind == weClosed
      doAssert (getMonoTime() - started).inMilliseconds < 500
    elif mode == "abort-full":
      let a = service.startConnect(url & "stall")
      let b = service.startConnect(url & "stall")
      service.abort()
      doAssert service.resultFor(a.operationId).error.kind == teCanceled
      doAssert service.resultFor(b.operationId).error.kind == teCanceled
      service.abort()
    elif mode == "shutdown-scope":
      block:
        let temporary = newWebSocketClient(bypassProxy = true)
        var first, second: ConnectionId
        try:
          first = temporary.opened(url)
          second = temporary.opened(url)
          let http = newHttpClient()
          try:
            doAssert http.get(url.replace("ws://", "http://") & "http").error.kind == teNone
            doAssert http.numInFlight() == 0 and http.queueLen() == 0
            doAssert not http.hasRequests()
            var response: RequestResult
            doAssert not http.pollForResult(response)
          finally:
            http.close()
        finally:
          temporary.abort()
        var completion: WebSocketResult
        doAssert not temporary.waitForResult(completion)
        doAssert temporary.eventFor(first).kind == weClosed
        doAssert temporary.eventFor(second).kind == weClosed
        var event: WebSocketEvent
        doAssert not temporary.pollForEvent(first, event)
        temporary.cancel(first)
        temporary.closeConnection(first)
        temporary.close()
    elif mode == "idle":
      let id = service.opened(url & "ping")
      sleep(80) # No receive call: pong must already have reached the independent peer.
      doAssert service.eventFor(id).message.data == "pong observed"
      let remote = service.opened(url & "close")
      sleep(80)
      doAssert service.eventFor(remote).kind == weClosed
    elif mode in ["cancel-send", "queued-deadline"]:
      let id = service.opened(url & "pause")
      let started = getMonoTime()
      let a = service.startSend(id, WebSocketMessage(kind: wmBinary,
        data: repeat('x', 32 * 1024 * 1024)))
      let b = service.startSend(id, WebSocketMessage(kind: wmText, data: "queued"),
        timeoutMs = if mode == "queued-deadline": 60 else: 1500)
      doAssertRaises IOError: discard service.text(id, "full")
      if mode == "cancel-send":
        sleep(40)
        service.cancel(id) # Bypasses the full command/completion budget.
      let expected = if mode == "queued-deadline": teTimeout else: teCanceled
      doAssert service.resultFor(a).error.kind == expected
      doAssert service.resultFor(b).error.kind == expected
      doAssert (getMonoTime() - started).inMilliseconds < 800
    elif mode == "slow-peer":
      let slow = service.opened(url & "pause")
      let blocked = service.startSend(slow, WebSocketMessage(kind: wmBinary,
        data: repeat('x', 32 * 1024 * 1024)))
      let fast = service.opened(url)
      let started = getMonoTime()
      let operation = service.text(fast, "other connection progresses")
      doAssert service.resultFor(operation).error.kind == teNone
      doAssert service.eventFor(fast).message.data == "other connection progresses"
      doAssert (getMonoTime() - started).inMilliseconds < 500
      service.cancel(slow)
      doAssert service.resultFor(blocked).error.kind == teCanceled
    elif mode == "cancel-receive":
      let id = service.opened(url)
      var waiter = Waiter(service: cast[pointer](service), id: id)
      var thread: Thread[ptr Waiter]
      createThread(thread, awaitEvent, addr waiter)
      sleep(40)
      service.cancel(id)
      joinThread(thread)
      doAssert waiter.received and waiter.event.kind == weClosed
      doAssert waiter.event.error.kind == teCanceled
    elif mode == "shutdown-full":
      discard service.startConnect(url & "flood")
      discard service.startConnect(url & "flood")
      sleep(80)
      service.close()
      service.close()
      var item: WebSocketResult
      for i in 0..<2: doAssert service.waitForResult(item)
      doAssert not service.waitForResult(item)
      doAssertRaises IOError: discard service.startConnect(url)
    else:
      let http = newHttpClient(maxInFlight = 1)
      try:
        # Upgrade both while HTTP is active, sharing only process-wide curl lifecycle.
        http.startRequest(RequestSpec(verb: hvGet, url: url.replace("ws://", "http://") & "http"))
        let first = service.startConnect(url)
        let second = service.startConnect(url)
        var a, b: WebSocketResult
        doAssert service.waitForResult(a) and service.waitForResult(b)
        doAssert a.error.kind == teNone and b.error.kind == teNone
        doAssert a.operationId != b.operationId
        var response: RequestResult
        doAssert http.waitForResult(response)
        doAssert response.error.kind == teNone and response.response.body == "relay http"
        var original = repeat('x', 200_000)
        let sendA = service.text(first.connectionId, original)
        original[0] = 'z' # Enqueued payload must be independent of caller mutation.
        let sendB = service.startSend(second.connectionId,
          WebSocketMessage(kind: wmBinary, data: "\0\xffbinary"))
        doAssert service.waitForResult(a) and service.waitForResult(b)
        doAssert a.error.kind == teNone and b.error.kind == teNone
        doAssert (a.operationId == sendA or b.operationId == sendA)
        doAssert (a.operationId == sendB or b.operationId == sendB)
        doAssert service.eventFor(first.connectionId).message.data == repeat('x', 200_000)
        let binary = service.eventFor(second.connectionId)
        doAssert binary.message.kind == wmBinary and binary.message.data == "\0\xffbinary"
        if mode == "http-first":
          let alias = http
          alias.close()
          http.close()
          doAssert service.resultFor(service.text(first.connectionId, "survives")).error.kind == teNone
          doAssert service.eventFor(first.connectionId).message.data == "survives"
        else:
          let alias = service
          alias.close()
          service.close()
          doAssert http.get(url.replace("ws://", "http://") & "http").response.body == "relay http"
      finally:
        http.close()

    echo "ok"
  finally:
    service.abort()

main()
