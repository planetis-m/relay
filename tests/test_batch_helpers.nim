import relay

proc main() =
  var batch: RequestBatch
  batch.get("http://127.0.0.1:1", tag = "first")
  batch.post("http://127.0.0.1:2", body = "x", tag = "second")

  doAssert batch.len == 2
  doAssert batch[0].verb == "GET"
  doAssert batch[0].tag == "first"
  doAssert batch[1].verb == "POST"
  doAssert batch[1].body == "x"

  var headers = emptyHttpHeaders()
  doAssert not headers.contains("Content-Type")
  headers["Content-Type"] = "application/json"
  doAssert headers.contains("content-type")
  doAssert headers["CONTENT-TYPE"] == "application/json"
  headers["content-type"] = "text/plain"
  doAssert headers["Content-Type"] == "text/plain"

when isMainModule:
  main()
