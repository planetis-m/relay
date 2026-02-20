import flowcurl

proc main() =
  var batch: RequestBatch
  batch.get("http://127.0.0.1:1", tag = "first")
  batch.post("http://127.0.0.1:2", body = "x", tag = "second")

  doAssert batch.len == 2
  doAssert batch[0].verb == "GET"
  doAssert batch[0].tag == "first"
  doAssert batch[1].verb == "POST"
  doAssert batch[1].body == "x"

when isMainModule:
  main()
