# Package
version = "0.1.3"
author = "planetis"
description = "Relay: parallel HTTP batching for Nim"
license = "MIT"
srcDir = "src"

requires "nim >= 2.2.0"

task test, "Run Relay tests":
  exec "nim c -r tests/test_batch_helpers.nim"
  exec "nim c -r tests/test_ordering_contract.nim"
  exec "nim c -r tests/test_lifecycle_contracts.nim"
