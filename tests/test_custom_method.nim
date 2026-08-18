import relay
import std/[locks, net, strutils]

type
  CaptureServerObj = object
    lock: Lock
    readyCond: Cond
    ready: bool
    stopRequested: bool
    port: Port
    startError: string
    expectedCount: int
    requestLines: seq[string]
    thread: Thread[ptr CaptureServerObj]
  CaptureServer = ref CaptureServerObj

proc captureServerMain(srvPtr: ptr CaptureServerObj) {.thread, raises: [].} =
  let srv = cast[CaptureServer](srvPtr)
  var sock: Socket
  try:
    sock = newSocket()
    sock.setSockOpt(OptReuseAddr, true)
    sock.bindAddr(Port(0), "127.0.0.1")
    sock.listen()

    acquire(srv.lock)
    srv.port = sock.getLocalAddr()[1]
    srv.ready = true
    signal(srv.readyCond)
    release(srv.lock)

    while true:
      acquire(srv.lock)
      let stop = srv.stopRequested
      let got = srv.requestLines.len
      let expected = srv.expectedCount
      release(srv.lock)
      if stop or got >= expected:
        break

      var clientSock: owned(Socket)
      try:
        sock.accept(clientSock)
      except CatchableError:
        acquire(srv.lock)
        let stopping = srv.stopRequested
        release(srv.lock)
        if stopping:
          break
        raise

      var line = ""
      try:
        line = clientSock.recvLine()
        clientSock.send(
          "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
      except CatchableError:
        discard
      clientSock.close()

      if line.len > 0:
        acquire(srv.lock)
        srv.requestLines.add(line)
        release(srv.lock)
  except Exception:
    acquire(srv.lock)
    srv.startError = getCurrentExceptionMsg()
    if not srv.ready:
      srv.ready = true
      signal(srv.readyCond)
    release(srv.lock)
  finally:
    if not sock.isNil:
      sock.close()

proc startCaptureServer(expectedCount: int): CaptureServer =
  new(result)
  initLock(result.lock)
  initCond(result.readyCond)
  result.ready = false
  result.stopRequested = false
  result.port = Port(0)
  result.startError = ""
  result.expectedCount = expectedCount
  result.requestLines = @[]
  createThread(result.thread, captureServerMain, cast[ptr CaptureServerObj](result))

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

proc stopCaptureServer(server: CaptureServer) =
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

proc main =
  let server = startCaptureServer(expectedCount = 2)
  defer:
    stopCaptureServer(server)

  let client = newRelay(maxInFlight = 1, defaultTimeoutMs = 2_000)
  defer: client.close()

  let url = "http://127.0.0.1:" & $int(server.port) & "/resource"

  let purgeResult = client.makeRequest("PURGE", url, requestId = 1, timeoutMs = 2_000)
  doAssert purgeResult.error.kind == teNone
  doAssert purgeResult.response.code == Http200
  doAssert purgeResult.response.request.verb == "PURGE"
  doAssert purgeResult.response.request.requestId == 1

  var batch: RequestBatch
  batch.addRequest("PROPFIND", url, requestId = 2, timeoutMs = 2_000)
  let batchResults = client.makeRequests(batch)
  doAssert batchResults.len == 1
  doAssert batchResults[0].error.kind == teNone
  doAssert batchResults[0].response.code == Http200
  doAssert batchResults[0].response.request.verb == "PROPFIND"

  acquire(server.lock)
  let lines = server.requestLines
  release(server.lock)

  doAssert lines.len == 2
  doAssert lines[0].startsWith("PURGE /resource ")
  doAssert lines[1].startsWith("PROPFIND /resource ")

when isMainModule:
  main()
