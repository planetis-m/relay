## Retry policy, exponential backoff, and retryable-status helpers.
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

proc initRetryPolicy*(maxAttempts = 5; baseDelayMs = RetryBaseDelayMs;
    maxDelayMs = RetryMaxDelayMs;
    jitterDivisor = RetryJitterDivisor): RetryPolicy =
  ## Builds a `RetryPolicy` with standard backoff defaults.
  RetryPolicy(
    maxAttempts: maxAttempts,
    baseDelayMs: baseDelayMs,
    maxDelayMs: maxDelayMs,
    jitterDivisor: jitterDivisor)

proc backoffBaseMs*(attempt: Positive; baseDelayMs: Natural; maxDelayMs: Natural): int =
  ## Exponential backoff base delay in ms, capped at `maxDelayMs`.
  ## Doubling stops at the cap, so the arithmetic cannot overflow.
  result = baseDelayMs
  if result > 0:
    var remaining = attempt - 1
    while remaining > 0 and result < maxDelayMs:
      if result > maxDelayMs - result:
        result = maxDelayMs
      else:
        result = result * 2
      dec remaining
  result = min(result, maxDelayMs)

proc backoffBaseMs*(attempt: Positive): int {.inline.} =
  backoffBaseMs(attempt, RetryBaseDelayMs, RetryMaxDelayMs)

proc retryDelayMs*(rng: var Rand; attempt: Positive; policy: RetryPolicy): int =
  ## Backoff delay in ms with jitter, per `policy`.
  let capped = backoffBaseMs(attempt, policy.baseDelayMs, policy.maxDelayMs)
  let jitterMax = max(1, capped div policy.jitterDivisor)
  let jitter = rng.rand(jitterMax)
  result = capped + jitter

proc retryDelayMs*(rng: var Rand; attempt: Positive; baseDelayMs: Natural;
    maxDelayMs: Natural): int {.inline.} =
  ## Backoff delay in ms with jitter, using the default jitter divisor.
  retryDelayMs(rng, attempt, initRetryPolicy(baseDelayMs = baseDelayMs,
    maxDelayMs = maxDelayMs))

proc isRetryable*(code: HttpCode): bool {.inline.} =
  ## Returns true for 408, 409, 425, 429, and any 5xx status.
  case code
  of Http408, Http409, Http425, Http429:
    result = true
  else:
    result = is5xx(code)
