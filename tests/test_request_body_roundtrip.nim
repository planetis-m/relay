import relay
import std/[asynchttpserver, asyncdispatch, locks, net]

type
  CapturedRequest = object
    reqMethod: HttpMethod
    body: string

  TestServerObj = object
    lock: Lock
    readyCond: Cond
    ready: bool
    stopRequested: bool
    port: Port
    startError: string
    expectedCount: int
    captured: seq[CapturedRequest]
    thread: Thread[ptr TestServerObj]
  TestServer = ref TestServerObj

proc teardownDispatcher() =
  try:
    var spins = 0
    while hasPendingOperations() and spins < 200:
      poll(0)
      inc spins
    setGlobalDispatcher(nil)
  except:
    discard

proc testServerMain(serverPtr: ptr TestServerObj) {.thread, raises: [].} =
  let server = cast[TestServer](serverPtr)
  proc runServer() {.async.} =
    var http = newAsyncHttpServer()

    proc cb(req: Request) {.async, gcsafe.} =
      acquire(server.lock)
      server.captured.add(CapturedRequest(reqMethod: req.reqMethod, body: req.body))
      release(server.lock)
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
      let got = server.captured.len
      let expected = server.expectedCount
      release(server.lock)
      if shouldStop or got >= expected:
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
  finally:
    teardownDispatcher()

proc startTestServer(expectedCount: int): TestServer =
  new(result)
  initLock(result.lock)
  initCond(result.readyCond)
  result.ready = false
  result.stopRequested = false
  result.port = Port(0)
  result.startError = ""
  result.expectedCount = expectedCount
  result.captured = @[]
  createThread(result.thread, testServerMain, cast[ptr TestServerObj](result))

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
  "http://127.0.0.1:" & $int(server.port) & "/echo"

proc main =
  let server = startTestServer(expectedCount = 3)
  defer:
    stopTestServer(server)

  var client = newRelay(maxInFlight = 1, defaultTimeoutMs = 2_000, maxRedirects = 5)
  defer: client.close()

  let url = testUrl(server)

  let postResult = client.post(url, body = "post-body", requestId = 1, timeoutMs = 2_000)
  doAssert postResult.error.kind == teNone
  doAssert postResult.response.code == 200

  let putResult = client.put(url, body = "put-body", requestId = 2, timeoutMs = 2_000)
  doAssert putResult.error.kind == teNone
  doAssert putResult.response.code == 200

  let patchResult = client.patch(url, body = "patch-body", requestId = 3, timeoutMs = 2_000)
  doAssert patchResult.error.kind == teNone
  doAssert patchResult.response.code == 200

  acquire(server.lock)
  let captured = server.captured
  release(server.lock)

  doAssert captured.len == 3
  doAssert captured[0].reqMethod == HttpPost
  doAssert captured[0].body == "post-body"
  doAssert captured[1].reqMethod == HttpPut
  doAssert captured[1].body == "put-body"
  doAssert captured[2].reqMethod == HttpPatch
  doAssert captured[2].body == "patch-body"

when isMainModule:
  main()
