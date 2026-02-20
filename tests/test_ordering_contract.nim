import relay
import std/algorithm

proc verifyContains(batchResults: ResponseBatch; expectedRequestIds: seq[int64]) =
  var gotRequestIds: seq[int64]
  var wantRequestIds = expectedRequestIds
  doAssert batchResults.len == expectedRequestIds.len
  for item in batchResults:
    gotRequestIds.add(item.response.request.requestId)
  gotRequestIds.sort()
  wantRequestIds.sort()
  doAssert gotRequestIds == wantRequestIds

proc main() =
  var client = newRelay(maxInFlight = 3, defaultTimeoutMs = 500, maxRedirects = 5)
  defer:
    client.close()

  var batch: RequestBatch
  # Unreachable loopback ports fail fast and still exercise async collection.
  batch.get("http://127.0.0.1:1", requestId = 1, timeoutMs = 500)
  batch.get("http://127.0.0.1:2", requestId = 2, timeoutMs = 500)
  batch.get("http://127.0.0.1:3", requestId = 3, timeoutMs = 500)

  let blockingResults = client.makeRequests(batch)
  verifyContains(blockingResults, @[1'i64, 2'i64, 3'i64])

  var asyncBatch: RequestBatch
  asyncBatch.get("http://127.0.0.1:4", requestId = 4, timeoutMs = 500)
  asyncBatch.get("http://127.0.0.1:5", requestId = 5, timeoutMs = 500)
  asyncBatch.get("http://127.0.0.1:6", requestId = 6, timeoutMs = 500)
  client.startRequests(asyncBatch)

  var asyncResults: ResponseBatch
  for _ in 0..<3:
    var item: BatchResult
    doAssert client.waitForResult(item)
    asyncResults.add(item)

  verifyContains(asyncResults, @[4'i64, 5'i64, 6'i64])

when isMainModule:
  main()
