import relay
import std/os

proc main =
  var client = newRelay(maxInFlight = 4, defaultTimeoutMs = 1_500, maxRedirects = 5)
  defer: client.close()

  let urls = [
    "https://example.com",
    "https://example.org",
    "https://www.iana.org"
  ]
  let totalRequests = 12
  let requestsPerBatch = 3

  var submitted = 0
  var completed = 0
  var nextRequestId = 1'i64

  while completed < totalRequests:
    # Producer step: occasionally submit a fresh batch with multiple requests.
    if submitted < totalRequests and (client.queueLen() + client.numInFlight()) < 6:
      var batch: RequestBatch
      var added = 0
      while added < requestsPerBatch and submitted < totalRequests:
        let url = urls[submitted mod urls.len]
        batch.get(url, requestId = nextRequestId, timeoutMs = 1_500)
        inc nextRequestId
        inc submitted
        inc added

      client.startRequests(batch)
      echo "submitted batchSize=", added, " totalSubmitted=", submitted

    # Consumer step: drain whichever result is ready (from any batch).
    var item: BatchResult
    if client.pollForResult(item):
      inc completed
      if item.error.kind == teNone:
        echo "completed id=", item.response.request.requestId,
          " status=", item.response.code
      else:
        echo "completed id=", item.response.request.requestId,
          " error=", item.error.kind
    else:
      sleep(10)

  echo "done submitted=", submitted, " completed=", completed

when isMainModule:
  main()
