import relay
import std/[algorithm, locks, net, os]

type
  StallServer = ref object
    lock: Lock
    readyCond: Cond
    ready: bool
    stopRequested: bool
    port: Port
    listener: Socket
    startError: string
    thread: Thread[StallServer]

proc stallServerMain(server: StallServer) {.thread, raises: [].} =
  var listener: Socket
  var client: owned(Socket)
  try:
    listener = newSocket()
    listener.setSockOpt(OptReuseAddr, true)
    listener.bindAddr(Port(0), "127.0.0.1")
    listener.listen()

    let (_, boundPort) = listener.getLocalAddr()
    acquire(server.lock)
    server.listener = listener
    server.port = boundPort
    server.ready = true
    signal(server.readyCond)
    release(server.lock)

    listener.accept(client)
    while true:
      acquire(server.lock)
      let shouldStop = server.stopRequested
      release(server.lock)
      if shouldStop:
        break
      sleep(10)
  except Exception:
    acquire(server.lock)
    server.startError = getCurrentExceptionMsg()
    if not server.ready:
      server.ready = true
      signal(server.readyCond)
    release(server.lock)
  finally:
    if not client.isNil:
      client.close()
    if not listener.isNil:
      listener.close()

proc startStallServer(): StallServer =
  new(result)
  initLock(result.lock)
  initCond(result.readyCond)
  result.ready = false
  result.stopRequested = false
  result.port = Port(0)
  result.listener = nil
  result.startError = ""
  createThread(result.thread, stallServerMain, result)

  acquire(result.lock)
  while not result.ready:
    wait(result.readyCond, result.lock)
  let err = result.startError
  release(result.lock)

  if err.len > 0:
    joinThread(result.thread)
    deinitCond(result.readyCond)
    deinitLock(result.lock)
    raise newException(IOError, "stall server start failed: " & err)

proc stopStallServer(server: StallServer) =
  if server.isNil:
    return
  acquire(server.lock)
  server.stopRequested = true
  let port = server.port
  release(server.lock)

  # Wake accept() without cross-thread close; listener is closed by server thread.
  if port != Port(0):
    try:
      var wake = newSocket()
      wake.connect("127.0.0.1", port)
      wake.close()
    except CatchableError:
      discard

  joinThread(server.thread)
  deinitCond(server.readyCond)
  deinitLock(server.lock)

proc waitForQueuedState(client: Relay; minQueueLen: int; timeoutMs: int): bool =
  var waitedMs = 0
  while waitedMs <= timeoutMs:
    if client.numInFlight() == 1 and client.queueLen() >= minQueueLen:
      return true
    sleep(10)
    inc waitedMs, 10

proc stallUrl(server: StallServer): string =
  "http://127.0.0.1:" & $int(server.port)

proc testClearQueueCancelsQueuedRequests() =
  let server = startStallServer()
  defer:
    stopStallServer(server)

  var client = newRelay(maxInFlight = 1, defaultTimeoutMs = 3_000, maxRedirects = 5)
  defer:
    client.close()

  let url = stallUrl(server)
  var batch: RequestBatch
  batch.get(url, requestId = 1, timeoutMs = 900)
  batch.get(url, requestId = 2, timeoutMs = 900)
  batch.get(url, requestId = 3, timeoutMs = 900)
  client.startRequests(batch)

  doAssert waitForQueuedState(client, minQueueLen = 2, timeoutMs = 1_000),
    "relay did not enter expected queue state"
  client.clearQueue()

  var seenRequestIds: seq[int64]
  var canceledCount = 0
  var timeoutCount = 0
  for _ in 0..<3:
    var item: BatchResult
    doAssert client.waitForResult(item)
    seenRequestIds.add(item.response.request.requestId)
    case item.error.kind
    of teCanceled:
      inc canceledCount
    of teTimeout:
      inc timeoutCount
    else:
      doAssert false, "unexpected error kind: " & $item.error.kind

  seenRequestIds.sort()
  doAssert seenRequestIds == @[1'i64, 2'i64, 3'i64]
  doAssert canceledCount == 2
  doAssert timeoutCount == 1

proc testMakeRequestsRequiresIdleClient() =
  let server = startStallServer()
  defer:
    stopStallServer(server)

  var client = newRelay(maxInFlight = 1, defaultTimeoutMs = 5_000, maxRedirects = 5)

  let url = stallUrl(server)
  var firstBatch: RequestBatch
  firstBatch.get(url, requestId = 11, timeoutMs = 5_000)
  client.startRequests(firstBatch)

  doAssert waitForQueuedState(client, minQueueLen = 0, timeoutMs = 1_000),
    "relay did not dispatch initial request"

  var secondBatch: RequestBatch
  secondBatch.get(url, requestId = 22, timeoutMs = 5_000)

  var raisedBusy = false
  try:
    discard client.makeRequests(secondBatch)
  except IOError:
    raisedBusy = true
  doAssert raisedBusy, "makeRequests should reject a non-idle client"

  client.abort()

proc testPollForResultEmptyQueue() =
  var client = newRelay(maxInFlight = 1)
  defer:
    client.close()

  var item: BatchResult
  doAssert not client.pollForResult(item)

proc main() =
  testClearQueueCancelsQueuedRequests()
  testMakeRequestsRequiresIdleClient()
  testPollForResultEmptyQueue()

when isMainModule:
  main()
