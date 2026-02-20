proc runTest(cmd: string) =
  echo "Running: " & cmd
  exec cmd

task test, "Run FlowCurl test suite":
  runTest "nim c -r tests/test_batch_helpers.nim"
  runTest "nim c -r tests/test_ordering_contract.nim"
