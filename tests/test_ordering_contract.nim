import relay
import std/algorithm

proc verifyContains(batchResults: ResponseBatch; expectedTags: seq[string]) =
  var gotTags: seq[string]
  var wantTags = expectedTags
  doAssert batchResults.len == expectedTags.len
  for item in batchResults:
    gotTags.add(item.response.request.tag)
  gotTags.sort()
  wantTags.sort()
  doAssert gotTags == wantTags

proc main() =
  var client = newRelay(maxInFlight = 3, defaultTimeoutMs = 500, maxRedirects = 5)
  defer:
    client.close()

  var batch: RequestBatch
  # Unreachable loopback ports fail fast and still exercise async collection.
  batch.get("http://127.0.0.1:1", tag = "a", timeoutMs = 500)
  batch.get("http://127.0.0.1:2", tag = "b", timeoutMs = 500)
  batch.get("http://127.0.0.1:3", tag = "c", timeoutMs = 500)

  let blockingResults = client.makeRequests(batch)
  verifyContains(blockingResults, @["a", "b", "c"])

  var asyncBatch: RequestBatch
  asyncBatch.get("http://127.0.0.1:4", tag = "d", timeoutMs = 500)
  asyncBatch.get("http://127.0.0.1:5", tag = "e", timeoutMs = 500)
  asyncBatch.get("http://127.0.0.1:6", tag = "f", timeoutMs = 500)
  client.startRequests(asyncBatch)

  var asyncResults: ResponseBatch
  for _ in 0..<3:
    var item: BatchResult
    doAssert client.waitForResult(item)
    asyncResults.add(item)

  verifyContains(asyncResults, @["d", "e", "f"])

when isMainModule:
  main()
