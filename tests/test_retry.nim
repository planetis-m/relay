import std/random
import relay

proc main =
  let policy = defaultRetryPolicy(
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

  doAssert isRetryableStatus(Http408)
  doAssert isRetryableStatus(Http409)
  doAssert isRetryableStatus(Http425)
  doAssert isRetryableStatus(Http429)
  doAssert isRetryableStatus(Http500)
  doAssert isRetryableStatus(Http503)
  doAssert not isRetryableStatus(Http200)
  doAssert not isRetryableStatus(Http400)
  doAssert not isRetryableStatus(Http404)

  doAssert not isRetryableTransport(teNone)
  doAssert isRetryableTransport(teTimeout)
  doAssert isRetryableTransport(teNetwork)
  doAssert isRetryableTransport(teDns)
  doAssert isRetryableTransport(teTls)
  doAssert isRetryableTransport(teInternal)
  doAssert not isRetryableTransport(teCanceled)
  doAssert not isRetryableTransport(teProtocol)

when isMainModule:
  main()
