import relay
import std/[algorithm, asynchttpserver, asyncdispatch, locks, net]

type
  TestServer = ref object
    lock: Lock
    readyCond: Cond
    ready: bool
    stopRequested: bool
    port: Port
    startError: string
    thread: Thread[TestServer]

proc testServerMain(server: TestServer) {.thread, raises: [].} =
  proc runServer() {.async.} =
    var http = newAsyncHttpServer()

    proc cb(req: Request) {.async, gcsafe.} =
      await req.respond(Http200, "OK")

    http.listen(Port(0), "127.0.0.1")

    acquire(server.lock)
    server.port = http.getPort()
    server.ready = true
    signal(server.readyCond)
    release(server.lock)

    while true:
      acquire(server.lock)
      let shouldStop = server.stopRequested
      release(server.lock)
      if shouldStop:
        break

      if http.shouldAcceptRequest():
        try:
          await http.acceptRequest(cb)
        except CatchableError:
          acquire(server.lock)
          let stopping = server.stopRequested
          release(server.lock)
          if stopping:
            break
          raise
      else:
        await sleepAsync(10)

    http.close()

  try:
    waitFor runServer()
  except Exception:
    acquire(server.lock)
    server.startError = getCurrentExceptionMsg()
    if not server.ready:
      server.ready = true
      signal(server.readyCond)
    release(server.lock)

proc startTestServer(): TestServer =
  new(result)
  initLock(result.lock)
  initCond(result.readyCond)
  result.ready = false
  result.stopRequested = false
  result.port = Port(0)
  result.startError = ""
  createThread(result.thread, testServerMain, result)

  acquire(result.lock)
  while not result.ready:
    wait(result.readyCond, result.lock)
  let err = result.startError
  release(result.lock)

  if err.len > 0:
    joinThread(result.thread)
    deinitCond(result.readyCond)
    deinitLock(result.lock)
    raise newException(IOError, "test server start failed: " & err)

proc stopTestServer(server: TestServer) =
  if server.isNil:
    return

  acquire(server.lock)
  server.stopRequested = true
  let port = server.port
  release(server.lock)

  # Wake async accept() so the server loop can observe stopRequested.
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

proc testUrl(server: TestServer): string =
  "http://127.0.0.1:" & $int(server.port) & "/ok"

proc verifyContains(batchResults: ResponseBatch; expectedRequestIds: seq[int64]) =
  var gotRequestIds: seq[int64]
  var wantRequestIds = expectedRequestIds
  doAssert batchResults.len == expectedRequestIds.len
  for item in batchResults:
    gotRequestIds.add(item.response.request.requestId)
  gotRequestIds.sort()
  wantRequestIds.sort()
  doAssert gotRequestIds == wantRequestIds

proc main =
  let server = startTestServer()
  defer:
    stopTestServer(server)

  var client = newRelay(maxInFlight = 3, defaultTimeoutMs = 2_000, maxRedirects = 5)
  defer: client.close()

  let url = testUrl(server)
  var batch: RequestBatch
  batch.get(url, requestId = 1, timeoutMs = 2_000)
  batch.get(url, requestId = 2, timeoutMs = 2_000)
  batch.get(url, requestId = 3, timeoutMs = 2_000)

  let blockingResults = client.makeRequests(batch)
  verifyContains(blockingResults, @[1'i64, 2, 3])

  var asyncBatch: RequestBatch
  asyncBatch.get(url, requestId = 4, timeoutMs = 2_000)
  asyncBatch.get(url, requestId = 5, timeoutMs = 2_000)
  asyncBatch.get(url, requestId = 6, timeoutMs = 2_000)
  client.startRequests(asyncBatch)

  var asyncResults: ResponseBatch
  for _ in 0..<3:
    var item: BatchResult
    doAssert client.waitForResult(item)
    asyncResults.add(item)

  verifyContains(asyncResults, @[4'i64, 5, 6])

when isMainModule:
  main()
