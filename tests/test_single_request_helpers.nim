import relay

const
  UnreachableA = "http://127.0.0.1:1"
  UnreachableB = "http://127.0.0.1:2"

proc checkResult(item: RequestResult; verb: HttpVerb; requestId: int64; url: string) =
  doAssert item.response.request.verb == verb
  doAssert item.response.request.requestId == requestId
  doAssert item.response.request.url == url
  doAssert item.error.kind != teNone

proc main =
  var client = newRelay(maxInFlight = 1, defaultTimeoutMs = 500)
  defer: client.close()

  var batch: RequestBatch
  batch.get(UnreachableA, requestId = 1)
  doAssert batch.len == 1
  doAssert batch[0].verb == hvGet

  checkResult(
    client.makeRequest(RequestSpec(
      verb: hvGet,
      url: UnreachableA,
      headers: emptyHttpHeaders(),
      body: "",
      requestId: 101,
      timeoutMs: 200
    )),
    hvGet,
    101,
    UnreachableA
  )

  checkResult(client.get(UnreachableA, requestId = 201, timeoutMs = 200), hvGet, 201, UnreachableA)
  checkResult(client.post(UnreachableA, body = "x", requestId = 202, timeoutMs = 200), hvPost, 202, UnreachableA)
  checkResult(client.put(UnreachableA, body = "y", requestId = 203, timeoutMs = 200), hvPut, 203, UnreachableA)
  checkResult(client.patch(UnreachableA, body = "z", requestId = 204, timeoutMs = 200), hvPatch, 204, UnreachableA)
  checkResult(client.delete(UnreachableA, requestId = 205, timeoutMs = 200), hvDelete, 205, UnreachableA)
  checkResult(client.head(UnreachableA, requestId = 206, timeoutMs = 200), hvHead, 206, UnreachableA)

  var inFlightBatch: RequestBatch
  let pendingCount = 8
  for i in 0..<pendingCount:
    inFlightBatch.get(UnreachableA, requestId = 301 + i.int64, timeoutMs = 200)
  client.startRequests(inFlightBatch)
  client.clearQueue()

  var raisedBusy = false
  try:
    discard client.makeRequest(RequestSpec(
      verb: hvGet,
      url: UnreachableB,
      headers: emptyHttpHeaders(),
      body: "",
      requestId: 302,
      timeoutMs: 200
    ))
  except IOError:
    raisedBusy = true
  doAssert raisedBusy, "makeRequest should reject a non-idle client"

  for _ in 0..<pendingCount:
    var drained: RequestResult
    doAssert client.waitForResult(drained)

when isMainModule:
  main()
