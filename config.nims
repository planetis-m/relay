switch("threads", "on")

when defined(linux) or defined(macosx):
  switch("passL", "-lcurl")
