import relay/http

proc main =
  let client = newHttpClient(maxInFlight = 8)
  try:
    var batch: RequestBatch
    batch.get("https://example.com", requestId = 1)
    batch.get("https://example.org", requestId = 2)

    let responses = client.makeRequests(batch)
    for item in responses:
      if item.error.kind == teNone:
        echo item.response.request.requestId, " code=", item.response.code,
          " bytes=", item.response.body.len
      else:
        echo item.response.request.requestId, " error=", item.error.kind,
          " ", item.error.message
  finally:
    client.close()

when isMainModule:
  main()
