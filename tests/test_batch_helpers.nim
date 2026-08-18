import relay

proc main =
  var batch: RequestBatch
  batch.get("http://127.0.0.1:1", requestId = 11)
  batch.post("http://127.0.0.1:2", body = "x", requestId = 22)
  batch.options("http://127.0.0.1:3", requestId = 33)
  batch.connect("http://127.0.0.1:4", requestId = 44)
  batch.trace("http://127.0.0.1:5", requestId = 55)

  doAssert batch.len == 5
  doAssert batch[0].verb == hvGet
  doAssert batch[0].requestId == 11
  doAssert batch[1].verb == hvPost
  doAssert batch[1].body == "x"
  doAssert batch[1].requestId == 22
  doAssert batch[2].verb == hvOptions
  doAssert batch[2].requestId == 33
  doAssert batch[3].verb == hvConnect
  doAssert batch[3].requestId == 44
  doAssert batch[4].verb == hvTrace
  doAssert batch[4].requestId == 55

  var headers = emptyHttpHeaders()
  doAssert not headers.contains("Content-Type")
  headers["Content-Type"] = "application/json"
  doAssert headers.contains("content-type")
  doAssert headers["CONTENT-TYPE"] == "application/json"
  headers["content-type"] = "text/plain"
  doAssert headers["Content-Type"] == "text/plain"

when isMainModule:
  main()
