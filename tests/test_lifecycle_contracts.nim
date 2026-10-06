import relay/http
import std/[algorithm, assertions, locks, monotimes, net, os, times]
from std/nativesockets import getSockName

type
  StallServerObj = object
    lock: Lock
    readyCond: Cond
    ready: bool
    stopRequested: bool
    port: Port
    listener: Socket
    startError: string
    thread: Thread[ptr StallServerObj]
  StallServer = ref StallServerObj
  ResultWaiterObj = object
    lock: Lock
    client: HttpClient
    started, done, received: bool
    requestId: int64
    error: TransportErrorKind
    thread: Thread[ptr ResultWaiterObj]
  ResultWaiter = ref ResultWaiterObj

proc resultWaiterMain(waiterPtr: ptr ResultWaiterObj) {.thread.} =
  let waiter = cast[ResultWaiter](waiterPtr)
  acquire(waiter.lock)
  waiter.started = true
  release(waiter.lock)
  var item: RequestResult
  let received = waiter.client.waitForResult(item)
  acquire(waiter.lock)
  waiter.received = received
  if received:
    waiter.requestId = item.response.request.requestId
    waiter.error = item.error.kind
  waiter.done = true
  release(waiter.lock)

proc awaitWaiter(waiter: ResultWaiter; completion: bool) =
  let deadline = getMonoTime() + initDuration(milliseconds = 3_000)
  while getMonoTime() < deadline:
    acquire(waiter.lock)
    let reached = if completion: waiter.done else: waiter.started
    release(waiter.lock)
    if reached: return
    sleep(1)
  # Shutdown cannot run while callers wait; terminate instead of hanging during join.
  quit("HTTP result waiter did not reach expected state", 1)

proc stallServerMain(serverPtr: ptr StallServerObj) {.thread, raises: [].} =
  let server = cast[StallServer](serverPtr)
  var listener: Socket
  var client: owned(Socket)
  try:
    listener = newSocket()
    listener.setSockOpt(OptReuseAddr, true)
    listener.bindAddr(Port(0), "127.0.0.1")
    listener.listen()

    let boundPort = getSockName(listener.getFd())
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
  except CatchableError:
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
  createThread(result.thread, stallServerMain, cast[ptr StallServerObj](result))

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
  server.thread = default(Thread[ptr StallServerObj])
  deinitCond(server.readyCond)
  deinitLock(server.lock)

proc waitForQueuedState(client: HttpClient; minQueueLen: int; timeoutMs: int): bool =
  result = false
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
  try:
    var client = newHttpClient(maxInFlight = 1, defaultTimeoutMs = 3_000, maxRedirects = 5)
    try:
      let url = stallUrl(server)
      var batch: RequestBatch
      batch.get(url, requestId = 1, timeoutMs = 900)
      batch.get(url, requestId = 2, timeoutMs = 900)
      batch.get(url, requestId = 3, timeoutMs = 900)
      # Capture size before startRequests(batch) drains the batch.
      let pending = batch.len
      client.startRequests(batch)

      doAssert waitForQueuedState(client, minQueueLen = 2, timeoutMs = 1_000),
        "relay did not enter expected queue state"
      client.clearQueue()

      var seenRequestIds: seq[int64] = @[]
      var canceledCount = 0
      var timeoutCount = 0
      for _ in 0..<pending:
        var item: RequestResult
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
    finally:
      client.close()
  finally:
    stopStallServer(server)

proc testPollForResultEmptyQueue() =
  let client = newHttpClient(maxInFlight = 1)
  try:
    var item: RequestResult
    doAssert not client.pollForResult(item)
  finally:
    client.close()

proc testConcurrentResultWaiters() =
  let server = startStallServer()
  let client = newHttpClient(maxInFlight = 2, defaultTimeoutMs = 150)
  let first = ResultWaiter(client: client)
  let second = ResultWaiter(client: client)
  initLock(first.lock)
  initLock(second.lock)
  createThread(first.thread, resultWaiterMain, cast[ptr ResultWaiterObj](first))
  createThread(second.thread, resultWaiterMain, cast[ptr ResultWaiterObj](second))
  first.awaitWaiter(completion = false)
  second.awaitWaiter(completion = false)
  # Only raw submission/retrieval are shared; blocking convenience helpers need exclusivity.
  var batch: RequestBatch
  batch.get(stallUrl(server), requestId = 10)
  batch.get(stallUrl(server), requestId = 20)
  client.startRequests(batch)
  first.awaitWaiter(completion = true)
  second.awaitWaiter(completion = true)
  joinThread(first.thread)
  joinThread(second.thread)
  try:
    doAssert first.received and second.received
    doAssert first.error == teTimeout and second.error == teTimeout
    var requestIds = @[first.requestId, second.requestId]
    requestIds.sort()
    doAssert requestIds == @[10'i64, 20'i64], "missing or duplicate completion"
    doAssert not client.hasRequests()
    var extra: RequestResult
    doAssert not client.pollForResult(extra)
  finally:
    client.close()
    deinitLock(first.lock)
    deinitLock(second.lock)
    stopStallServer(server)

proc main() =
  testClearQueueCancelsQueuedRequests()
  testPollForResultEmptyQueue()
  testConcurrentResultWaiters()

when isMainModule:
  main()
