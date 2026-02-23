switch("threads", "on")
switch("mm", "atomicArc")

# libcurl
switch("passC", "-DCURL_DISABLE_TYPECHECK")

when not defined(windows):
  switch("passL", "-lcurl")

# --- Platform-specific settings ---
when defined(macosx):
  switch("passC", "-I" & staticExec("brew --prefix curl") & "/include")
  switch("passL", "-L" & staticExec("brew --prefix curl") & "/lib")
elif defined(windows):
  switch("cc", "vcc")
  let vcpkgRoot = getEnv("VCPKG_ROOT", "C:/vcpkg/installed/x64-windows-release")
  switch("passC", "-I" & vcpkgRoot & "/include")
  switch("passL", vcpkgRoot & "/lib/libcurl.lib")

when defined(threadSanitizer) or defined(addressSanitizer):
  switch("define", "useMalloc")
  switch("debugger", "native")
  switch("define", "noSignalHandler")

  when defined(windows):
    when defined(addressSanitizer):
      switch("passC", "/fsanitize=address")
    else:
      {.warning: "Thread Sanitizer is not supported on Windows.".}
  else:
    # Linux/macOS: keep Nim's default compiler (gcc on Linux, clang on macOS).
    when defined(threadSanitizer):
      switch("passC", "-fsanitize=thread -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer")
      switch("passL", "-fsanitize=thread -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer")
    elif defined(addressSanitizer):
      switch("passC", "-fsanitize=address -fno-omit-frame-pointer")
      switch("passL", "-fsanitize=address -fno-omit-frame-pointer")
