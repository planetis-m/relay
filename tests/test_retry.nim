import std/random
import relay

proc main =
  let policy = initRetryPolicy(
    maxAttempts = 5,
    baseDelayMs = RetryBaseDelayMs,
    maxDelayMs = RetryMaxDelayMs,
    jitterDivisor = RetryJitterDivisor
  )

  var rng = initRand(42)
  var delays: seq[int] = @[]
  for attempt in 1..policy.maxAttempts:
    delays.add(retryDelayMs(rng, attempt, policy))

  doAssert delays.len == policy.maxAttempts
  doAssert delays[0] >= backoffBaseMs(1, policy.baseDelayMs, policy.maxDelayMs)
  doAssert backoffBaseMs(1, 250, 8000) == 250
  doAssert backoffBaseMs(2, 250, 8000) == 500
  doAssert backoffBaseMs(6, 250, 8000) == 8000

  doAssert isRetryable(Http408)
  doAssert isRetryable(Http409)
  doAssert isRetryable(Http425)
  doAssert isRetryable(Http429)
  doAssert isRetryable(Http500)
  doAssert isRetryable(Http503)
  doAssert not isRetryable(Http200)
  doAssert not isRetryable(Http400)
  doAssert not isRetryable(Http404)

  doAssert not isRetryable(teNone)
  doAssert isRetryable(teTimeout)
  doAssert isRetryable(teNetwork)
  doAssert isRetryable(teDns)
  doAssert isRetryable(teTls)
  doAssert isRetryable(teInternal)
  doAssert not isRetryable(teCanceled)
  doAssert not isRetryable(teProtocol)

when isMainModule:
  main()
