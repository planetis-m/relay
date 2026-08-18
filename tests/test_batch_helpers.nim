import relay

proc main =
  var batch: RequestBatch
  batch.get("http://127.0.0.1:1", requestId = 11)
  batch.post("http://127.0.0.1:2", body = "x", requestId = 22)

  doAssert batch.len == 2
  doAssert batch[0].verb == hvGet
  doAssert batch[0].requestId == 11
  doAssert batch[1].verb == hvPost
  doAssert batch[1].body == "x"
  doAssert batch[1].requestId == 22

  var headers = emptyHttpHeaders()
  doAssert not headers.contains("Content-Type")
  headers["Content-Type"] = "application/json"
  doAssert headers.contains("content-type")
  doAssert headers["CONTENT-TYPE"] == "application/json"
  headers["content-type"] = "text/plain"
  doAssert headers["Content-Type"] == "text/plain"

when isMainModule:
  main()
