# Package
version = "0.1.0"
author = "Ageralis"
description = "FlowCurl: ordered, parallel HTTP batching for Nim"
license = "MIT"
srcDir = "src"

requires "nim >= 2.2.0"

task test, "Run FlowCurl tests":
  exec "nim c -r tests/test_batch_helpers.nim"
  exec "nim c -r tests/test_ordering_contract.nim"
