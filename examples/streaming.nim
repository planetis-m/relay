import relay/http

proc main =
  let client = newHttpClient(maxInFlight = 2)
  try:
    var batch: RequestBatch
    batch.get("https://example.com", requestId = 1)
    batch.get("https://example.org", requestId = 2)
    batch.get("https://iana.org", requestId = 3)

    # Capture size before startRequests(batch) drains the batch.
    let pending = batch.len
    client.startRequests(batch)

    for _ in 0..<pending:
      var item: RequestResult
      if client.waitForResult(item):
        if item.error.kind == teNone:
          echo item.response.request.requestId, " -> ", item.response.code
        else:
          echo item.response.request.requestId, " failed"
  finally:
    client.close()

when isMainModule:
  main()
