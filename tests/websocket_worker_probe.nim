## Bounded independent wire fixtures; no external URLs or provider calls.
import std/[assertions, monotimes, os, strutils, times]
import relay/http
import relay/websocket

proc resultFor(service: WebSocketClient; operation: OperationId): WebSocketResult =
  result = WebSocketResult()
  doAssert service.waitForResult(result)
  doAssert result.operationId == operation

proc eventFor(service: WebSocketClient; id: ConnectionId; timeoutMs = 1500): WebSocketEvent =
  result = WebSocketEvent()
  doAssert service.waitForEvent(id, result, timeoutMs)

proc opened(service: WebSocketClient; url: string): ConnectionId =
  let ids = service.startConnect(url)
  doAssert service.resultFor(ids.operationId).error.kind == teNone
  result = ids.connectionId

proc text(service: WebSocketClient; id: ConnectionId; data: sink string): OperationId =
  service.startSend(id, WebSocketMessage(kind: wmText, data: data))

proc received(client: WebSocketClient; id: ConnectionId): WebSocketMessage =
  var item = client.receive(id)
  doAssert item.kind == wrMessage and item.error.kind == teNone
  result = move item.message

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
    if mode == "blocking-client":
      let client = newWebSocketClient(maxConnections = 1, maxCommands = 1,
        defaultTimeoutMs = 1500, maxMessageBytes = 8, bypassProxy = true)
      try:
        let opened = client.connect(url)
        doAssert opened.error.kind == teNone
        let id = opened.connectionId
        let sent = client.send(id, "echo")
        doAssert sent.error.kind == teNone and sent.connectionId == id
        doAssert sent.operationId != opened.operationId
        doAssert client.received(id).data == "echo"
        let timedOut = client.receive(id, timeoutMs = 30)
        doAssert timedOut.kind == wrTimedOut and timedOut.error.kind == teTimeout
        doAssert client.send(id, "alive").error.kind == teNone
        doAssert client.received(id).data == "alive"
        var retained = "owned"
        doAssert client.send(id, retained).error.kind == teNone
        retained[0] = 'X'
        doAssert client.received(id).data == "owned"
        var transferred = "moved"
        doAssert client.send(id, move transferred).error.kind == teNone
        doAssert transferred.len == 0
        doAssert client.received(id).data == "moved"
        doAssert client.send(id, "").error.kind == teNone
        doAssert client.received(id).data == ""
        doAssert client.send(id, WebSocketMessage(kind: wmBinary, data: "\0\xffbinary"))
          .error.kind == teNone
        let binary = client.received(id)
        doAssert binary.kind == wmBinary and binary.data == "\0\xffbinary"
        client.closeConnection(id)
        doAssert client.connect(url).error.kind == teNone
      finally:
        client.close()
    elif mode == "blocking-failure":
      let peer = newWebSocketClient(maxConnections = 1,
        defaultTimeoutMs = 1500, bypassProxy = true)
      try:
        for invalid in [url & "bad", url.replace("ws://", "http://"),
            url.replace("ws://", "ws://user:pass@")]:
          doAssert peer.connect(invalid).error.kind != teNone
        let opened = peer.connect(url & "close")
        doAssert opened.error.kind == teNone
        sleep(80)
        let terminal = peer.receive(opened.connectionId)
        doAssert terminal.kind == wrClosed and terminal.error.kind == teCanceled
        doAssert terminal.error.message == "Peer closed the WebSocket connection"
        doAssert peer.connect(url).error.kind == teNone
      finally:
        peer.close()
    elif mode == "blocking-timeouts":
      let client = newWebSocketClient(maxConnections = 1, bypassProxy = true)
      try:
        doAssert client.connect(url & "stall", timeoutMs = 30).error.kind == teTimeout
        let opened = client.connect(url & "pause")
        doAssert opened.error.kind == teNone
        let sent = client.send(opened.connectionId,
          WebSocketMessage(kind: wmBinary, data: repeat('x', 32 * 1024 * 1024)),
          timeoutMs = 60)
        doAssert sent.error.kind == teTimeout
        let terminal = client.receive(opened.connectionId)
        doAssert terminal.kind == wrClosed and terminal.error.kind == teTimeout
        let next = client.connect(url & "disconnect-send")
        doAssert next.error.kind == teNone
        let failed = client.send(next.connectionId,
          WebSocketMessage(kind: wmBinary, data: repeat('x', 32 * 1024 * 1024)))
        doAssert failed.error.kind == teNetwork and failed.error.curlCode > 0
        doAssert client.receive(next.connectionId).kind == wrClosed
        doAssert client.connect(url).error.kind == teNone
      finally:
        client.close()
    elif mode == "blocking-disposal":
      let slow = service.connect(url & "flood")
      let healthy = service.connect(url)
      doAssert slow.error.kind == teNone and healthy.error.kind == teNone
      sleep(80)
      service.closeConnection(slow.connectionId)
      var event: WebSocketEvent
      doAssert not service.pollForEvent(slow.connectionId, event)
      let replacement = service.connect(url & "no-close")
      doAssert replacement.error.kind == teNone
      doAssert service.send(replacement.connectionId, "unread").error.kind == teNone
      sleep(40)
      let started = getMonoTime()
      service.closeConnection(replacement.connectionId)
      doAssert (getMonoTime() - started).inMilliseconds < 500
      doAssert not service.pollForEvent(replacement.connectionId, event)
      doAssert service.send(healthy.connectionId, "survives disposal").error.kind == teNone
      doAssert service.received(healthy.connectionId).data == "survives disposal"
      let pending = service.startConnect(url & "stall")
      let closingStarted = getMonoTime()
      service.closeConnection(pending.connectionId)
      doAssert (getMonoTime() - closingStarted).inMilliseconds < 500
      doAssert service.resultFor(pending.operationId).error.kind == teCanceled
      doAssert not service.pollForEvent(pending.connectionId, event)
      doAssert service.connect(url).error.kind == teNone
    elif mode == "blocking-close-pending":
      let slow = service.connect(url & "pause")
      let healthy = service.connect(url)
      doAssert slow.error.kind == teNone and healthy.error.kind == teNone
      let pending = service.startSend(slow.connectionId,
        WebSocketMessage(kind: wmBinary, data: repeat('x', 32 * 1024 * 1024)))
      service.closeConnection(slow.connectionId)
      doAssert service.resultFor(pending).error.kind == teCanceled
      doAssert service.send(healthy.connectionId, "healthy").error.kind == teNone
      doAssert service.received(healthy.connectionId).data == "healthy"
    elif mode == "close-handshake":
      let local = service.opened(url & "close-handshake")
      service.startCloseConnection(local)
      doAssert service.eventFor(local).error.kind == teCanceled
      let remote = service.opened(url & "close")
      doAssert service.eventFor(remote).error.kind == teCanceled
    elif mode == "close-deadline":
      let client = newWebSocketClient(bypassProxy = true, closeTimeoutMs = 400)
      try:
        let id = client.opened(url & "close-deadline")
        let pending = client.startSend(id,
          WebSocketMessage(kind: wmBinary, data: repeat('x', 32 * 1024 * 1024)))
        # The peer has seen the unfinished frame and stopped reading it.
        doAssert client.eventFor(id).message.data == "close barrier"
        let started = getMonoTime()
        client.startCloseConnection(id)
        doAssert client.eventFor(id).error.kind == teCanceled
        doAssert (getMonoTime() - started).inMilliseconds < 550,
          "Peer close reply restarted the local close deadline"
        doAssert client.resultFor(pending).error.kind == teCanceled
      finally:
        client.close()
    elif mode == "cancel-close":
      let id = service.opened(url & "pause")
      let pending = service.startSend(id,
        WebSocketMessage(kind: wmBinary, data: repeat('x', 32 * 1024 * 1024)))
      service.startCloseConnection(id)
      service.cancel(id)
      service.startCloseConnection(id)
      let terminal = service.eventFor(id)
      doAssert terminal.kind == weClosed and terminal.error.message == "WebSocket canceled"
      doAssert service.resultFor(pending).error.kind == teCanceled
    elif mode.startsWith("tls"):
      let response = service.connect(url)
      if mode == "tls-accept":
        doAssert response.error.kind == teNone
        doAssert service.send(response.connectionId, "secure echo").error.kind == teNone
        doAssert service.received(response.connectionId).data == "secure echo"
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
    elif mode in ["disconnect", "disconnect-send"]:
      let id = service.opened(url & mode)
      if mode == "disconnect-send":
        let operation = service.startSend(id, WebSocketMessage(kind: wmBinary,
          data: repeat('x', 32 * 1024 * 1024)))
        let completion = service.resultFor(operation)
        doAssert completion.error.kind == teNetwork and completion.error.curlCode > 0
        doAssert completion.error.kind.isRetryable()
      let terminal = service.eventFor(id)
      doAssert terminal.kind == weClosed
      doAssert terminal.error.kind == teNetwork and terminal.error.curlCode > 0
      doAssert terminal.error.kind.isRetryable()
      let healthy = service.opened(url)
      doAssert service.resultFor(service.text(healthy, "healthy")).error.kind == teNone
      doAssert service.eventFor(healthy).message.data == "healthy"
    elif mode in ["pressure", "bytes"]:
      let slow = service.opened(url & "flood")
      let fast = service.opened(url)
      sleep(80)
      # A full event queue preserves accepted messages, then terminal status.
      for i in 0..<(if mode == "bytes": 1 else: 2):
        doAssert service.eventFor(slow).message.data == "flood" & $i
      let terminal = service.eventFor(slow)
      doAssert terminal.kind == weClosed
      doAssert terminal.error.message.contains("overflow")
      doAssert terminal.error.kind == teProtocol and terminal.error.curlCode == 0
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
      # Allow the 4 MiB echo time to arrive on slower CI runners.
      let timeoutMs = if mode == "partial": 3500 else: 1500
      doAssert service.eventFor(id, timeoutMs).message.data == data
    elif mode == "idle-close":
      let id = service.opened(url & "no-close")
      let started = getMonoTime()
      service.startCloseConnection(id)
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
