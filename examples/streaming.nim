import flowcurl

proc main() =
  var client = newOrderedClient(maxInFlight = 2)
  defer:
    client.close()

  var batch: RequestBatch
  batch.get("https://example.com", tag = "one")
  batch.get("https://example.org", tag = "two")
  batch.get("https://iana.org", tag = "three")

  client.startRequests(batch)

  for _ in 0..<3:
    var item: BatchResult
    if client.waitForResult(item):
      if item.error.kind == teNone:
        echo item.response.request.tag, " -> ", item.response.code
      else:
        echo item.response.request.tag, " failed"

when isMainModule:
  main()
