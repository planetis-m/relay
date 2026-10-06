import relay/http
import std/assertions

const
  UnreachableA = "http://127.0.0.1:1"

proc checkResult(item: RequestResult; verb: HttpVerb; requestId: int64; url: string) =
  doAssert item.response.request.verb == verb
  doAssert item.response.request.requestId == requestId
  doAssert item.response.request.url == url
  doAssert item.error.kind != teNone

proc main =
  let client = newHttpClient(maxInFlight = 1, defaultTimeoutMs = 500)
  try:
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
    checkResult(client.options(UnreachableA, requestId = 207, timeoutMs = 200), hvOptions, 207, UnreachableA)
    checkResult(client.connect(UnreachableA, requestId = 208, timeoutMs = 200), hvConnect, 208, UnreachableA)
    checkResult(client.trace(UnreachableA, requestId = 209, timeoutMs = 200), hvTrace, 209, UnreachableA)

    var inFlightBatch: RequestBatch
    let pendingCount = 8
    for i in 0..<pendingCount:
      inFlightBatch.get(UnreachableA, requestId = 301 + i.int64, timeoutMs = 200)
    client.startRequests(inFlightBatch)
    client.clearQueue()

    for _ in 0..<pendingCount:
      var drained: RequestResult
      doAssert client.waitForResult(drained)
  finally:
    client.close()

when isMainModule:
  main()
