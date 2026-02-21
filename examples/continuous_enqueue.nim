import relay
import std/os

proc main() =
  var client = newRelay(maxInFlight = 4, defaultTimeoutMs = 1_500, maxRedirects = 5)
  defer:
    client.close()

  let urls = [
    "https://example.com",
    "https://example.org",
    "https://www.iana.org"
  ]
  let iterations = 4
  let requestsPerBatch = 3

  var submitted = 0
  var completed = 0
  var nextRequestId = 1'i64

  # Every loop iteration creates a new batch with multiple GET requests.
  for loopIdx in 0..<iterations:
    var batch: RequestBatch
    for i in 0..<requestsPerBatch:
      let url = urls[(loopIdx + i) mod urls.len]
      batch.get(url, requestId = nextRequestId, timeoutMs = 1_500)
      inc nextRequestId

    client.startRequests(batch)
    submitted += requestsPerBatch
    echo "submitted loop=", loopIdx + 1, " batchSize=", requestsPerBatch,
      " totalSubmitted=", submitted

    var item: BatchResult
    while client.pollForResult(item):
      inc completed
      if item.error.kind == teNone:
        echo "completed id=", item.response.request.requestId,
          " status=", item.response.code
      else:
        echo "completed id=", item.response.request.requestId,
          " error=", item.error.kind

    sleep(80)

  while completed < submitted:
    var item: BatchResult
    if client.waitForResult(item):
      inc completed
      if item.error.kind == teNone:
        echo "completed id=", item.response.request.requestId,
          " status=", item.response.code
      else:
        echo "completed id=", item.response.request.requestId,
          " error=", item.error.kind
    else:
      break

  echo "done submitted=", submitted, " completed=", completed

when isMainModule:
  main()
