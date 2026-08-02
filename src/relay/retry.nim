import std/random
import ./http_status

const
  RetryBaseDelayMs* = 250
  RetryMaxDelayMs* = 8_000
  RetryJitterDivisor* = 4

type
  RetryPolicy* = object
    maxAttempts*: int
    baseDelayMs*: int
    maxDelayMs*: int
    jitterDivisor*: int

proc defaultRetryPolicy*(maxAttempts = 5;
    baseDelayMs = RetryBaseDelayMs;
    maxDelayMs = RetryMaxDelayMs;
    jitterDivisor = RetryJitterDivisor): RetryPolicy =
  RetryPolicy(
    maxAttempts: maxAttempts,
    baseDelayMs: baseDelayMs,
    maxDelayMs: maxDelayMs,
    jitterDivisor: max(1, jitterDivisor)
  )

proc backoffBaseMs*(attempt: int; retryBaseDelayMs: int;
    retryMaxDelayMs: int): int =
  let exponent = if attempt <= 1: 0 else: attempt - 1
  let raw = retryBaseDelayMs shl exponent
  result = min(raw, retryMaxDelayMs)

proc backoffBaseMs*(attempt: int): int =
  backoffBaseMs(attempt, RetryBaseDelayMs, RetryMaxDelayMs)

proc retryDelayMs*(rng: var Rand; attempt: int; retryBaseDelayMs: int;
    retryMaxDelayMs: int): int =
  let capped = backoffBaseMs(attempt, retryBaseDelayMs, retryMaxDelayMs)
  let jitterMax = max(1, capped div RetryJitterDivisor)
  let jitter = rng.rand(jitterMax)
  result = capped + jitter

proc retryDelayMs*(rng: var Rand; attempt: int; policy: RetryPolicy): int =
  let capped = backoffBaseMs(attempt, policy.baseDelayMs, policy.maxDelayMs)
  let jitterMax = max(1, capped div max(1, policy.jitterDivisor))
  let jitter = rng.rand(jitterMax)
  result = capped + jitter

proc isRetryableStatus*(code: HttpCode): bool {.inline.} =
  ## Returns true for 408, 409, 425, 429, and any 5xx status.
  case code
  of Http408, Http409, Http425, Http429:
    result = true
  else:
    result = is5xx(code)
