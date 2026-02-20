import flowcurl

proc main() =
  var client = newOrderedClient(maxInFlight = 8)
  defer:
    client.close()

  var batch: RequestBatch
  batch.get("https://example.com", tag = "example")
  batch.get("https://example.org", tag = "example-org")

  let responses = client.makeRequests(batch)
  for item in responses:
    if item.error.kind == teNone:
      echo item.response.request.tag, " code=", item.response.code,
        " bytes=", item.response.body.len
    else:
      echo item.response.request.tag, " error=", item.error.kind,
        " ", item.error.message

when isMainModule:
  main()
