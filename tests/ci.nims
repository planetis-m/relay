import std/strutils

proc runTest(cmd: string) =
  echo "Running: " & cmd
  exec cmd

proc modeFlags(): string =
  when defined(addressSanitizer):
    result = " -d:addressSanitizer"
  elif defined(threadSanitizer):
    result = " -d:threadSanitizer"
  else:
    result = ""

proc modeTag(flags: string): string =
  if flags.contains("-d:addressSanitizer"):
    result = "asan"
  elif flags.contains("-d:threadSanitizer"):
    result = "tsan"
  else:
    result = "default"

proc runSuite(flags: string) =
  let tag = modeTag(flags)
  let testFlags = flags & " -d:useMalloc"
  runTest "nim c -r" & testFlags & " --nimcache:.nimcache/" & tag & "/test_batch_helpers tests/test_batch_helpers.nim"
  runTest "nim c -r" & testFlags & " --nimcache:.nimcache/" & tag & "/test_single_request_helpers tests/test_single_request_helpers.nim"
  runTest "nim c -r" & testFlags & " --nimcache:.nimcache/" & tag & "/test_ordering_contract tests/test_ordering_contract.nim"
  runTest "nim c -r" & testFlags & " --nimcache:.nimcache/" & tag & "/test_lifecycle_contracts tests/test_lifecycle_contracts.nim"

task test, "Run Relay test suite":
  runSuite(modeFlags())

task asan, "Run Relay test suite with AddressSanitizer":
  runSuite(" -d:addressSanitizer")

task tsan, "Run Relay test suite with ThreadSanitizer":
  runSuite(" -d:threadSanitizer")

task testAll, "Run default, ASan, and TSan suites":
  runSuite("")
  runSuite(" -d:addressSanitizer")
  when not defined(windows):
    runSuite(" -d:threadSanitizer")
