import relay

proc main() =
  var client = newRelay(maxInFlight = 2)
  defer:
    client.close()

  var batch: RequestBatch
  batch.get("https://example.com", requestId = 1)
  batch.get("https://example.org", requestId = 2)
  batch.get("https://iana.org", requestId = 3)

  client.startRequests(batch)

  for _ in 0..<3:
    var item: BatchResult
    if client.waitForResult(item):
      if item.error.kind == teNone:
        echo item.response.request.requestId, " -> ", item.response.code
      else:
        echo item.response.request.requestId, " failed"

when isMainModule:
  main()
