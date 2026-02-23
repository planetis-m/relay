# Local build config for tests
switch("path", "../src")

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
