# relay

Relay is a general-purpose Nim HTTP batching client built on libcurl multi.

It gives you:

- bounded parallel requests (`maxInFlight`)
- batch-oriented request construction
- blocking and non-blocking result collection
- completion-order result delivery

## Install

```bash
nimble install
```

## Quick Start (Blocking Batch)

```nim
import relay

var client = newRelay(maxInFlight = 8)
defer: client.close()

var batch: RequestBatch
batch.get("https://example.com", requestId = 1)
batch.get("https://example.org", requestId = 2)

for item in client.makeRequests(batch):
  if item.error.kind == teNone:
    echo item.response.request.requestId, " status=", item.response.code
  else:
    echo item.response.request.requestId, " error=", item.error.kind,
      " ", item.error.message
```

## Quick Start (Blocking Single Request)

```nim
import relay

var client = newRelay()
defer: client.close()

let item = client.get("https://example.com", requestId = 7)
if item.error.kind == teNone:
  echo item.response.request.requestId, " status=", item.response.code
else:
  echo item.error.kind, " ", item.error.message
```

## Async Pattern (`startRequests` + drain)

Use this when your app has its own scheduling loop.

```nim
import relay

var client = newRelay(maxInFlight = 16)
defer: client.close()

var batch: RequestBatch
batch.post("https://example.com/api", body = """{"x":1}""", requestId = 101)
batch.post("https://example.com/api", body = """{"x":2}""", requestId = 102)
client.startRequests(batch)

var pending = batch.len
while pending > 0:
  var item: RequestResult
  if client.waitForResult(item):
    dec pending
    if item.error.kind == teNone:
      echo item.response.request.requestId, " -> ", item.response.code
    else:
      echo item.response.request.requestId, " failed: ", item.error.message
```

## API Reference

Public API is exported from `src/relay.nim`.

### Core Types

- `HttpHeaders = seq[tuple[name: string, value: string]]`
- `HttpVerb = enum hvGet = "GET", hvPost = "POST", hvPut = "PUT", hvPatch = "PATCH", hvDelete = "DELETE", hvHead = "HEAD"`
- `RequestSpec`: request definition (`verb`, `url`, `headers`, `body`, `requestId`,
  `timeoutMs`)
- `RequestBatch`: mutable batch builder
- `RequestResult = tuple[response: Response, error: TransportError]`
- `RequestResults = seq[RequestResult]`
- `TransportErrorKind`:
  - `teNone`
  - `teTimeout`
  - `teNetwork`
  - `teDns`
  - `teTls`
  - `teCanceled`
  - `teProtocol`
  - `teInternal`

### Client Lifecycle

```nim
proc newRelay*(maxInFlight = 16; defaultTimeoutMs = 60_000;
    maxRedirects = 10): Relay
proc close*(client: Relay)
proc abort*(client: Relay)
```

- `newRelay` starts Relay’s internal worker thread.
- `close` waits for queued/in-flight work to finish, then shuts down cleanly.
- `abort` cancels pending/in-flight work and stops quickly.

### Threading & Lifecycle Constraints

- Memory model: this repo pins `atomicArc` in `config.nims`.
  Relay shares `ref` objects (`Relay`, `RequestWrap`) across threads, so atomic
  refcounting is the safe default.
- Relay ownership: treat a `Relay` instance as single-owner from the creating
  thread.
- `close` / `abort`: call from the same thread that created the `Relay`; do not
  invoke them concurrently from other threads.
- Relay instances: current lifecycle uses global libcurl init/cleanup per
  instance. Prefer a single active `Relay` instance in a process.

### Building Request Batches

```nim
proc addRequest*(batch: var RequestBatch; verb: HttpVerb; url: string;
    headers = emptyHttpHeaders();
    body = ""; requestId = 0'i64; timeoutMs = 0)
proc get*(batch: var RequestBatch; url: string; headers = emptyHttpHeaders();
    requestId = 0'i64; timeoutMs = 0)
proc post*(batch: var RequestBatch; url: string; headers = emptyHttpHeaders();
    body = ""; requestId = 0'i64; timeoutMs = 0)
proc put*(batch: var RequestBatch; url: string; headers = emptyHttpHeaders();
    body = ""; requestId = 0'i64; timeoutMs = 0)
proc patch*(batch: var RequestBatch; url: string; headers = emptyHttpHeaders();
    body = ""; requestId = 0'i64; timeoutMs = 0)
proc delete*(batch: var RequestBatch; url: string; headers = emptyHttpHeaders();
    requestId = 0'i64; timeoutMs = 0)
proc head*(batch: var RequestBatch; url: string; headers = emptyHttpHeaders();
    requestId = 0'i64; timeoutMs = 0)
```

Utilities:

```nim
proc len*(batch: RequestBatch): int
proc `[]`*(batch: RequestBatch; i: int): lent RequestSpec
proc emptyHttpHeaders*(): HttpHeaders
proc contains*(headers: HttpHeaders; key: string): bool
proc `[]`*(headers: HttpHeaders; key: string): string
proc `[]=`*(headers: var HttpHeaders; key, value: string)
```

### Executing Requests

```nim
proc startRequests*(client: Relay; batch: sink RequestBatch)
proc waitForResult*(client: Relay; outResult: var RequestResult): bool
proc pollForResult*(client: Relay; outResult: var RequestResult): bool
proc makeRequests*(client: Relay; batch: sink RequestBatch): RequestResults
proc makeRequest*(client: Relay; request: sink RequestSpec): RequestResult
proc get*(client: Relay; url: string; headers = emptyHttpHeaders();
    requestId = 0'i64; timeoutMs = 0): RequestResult
proc post*(client: Relay; url: string; headers = emptyHttpHeaders();
    body = ""; requestId = 0'i64; timeoutMs = 0): RequestResult
proc put*(client: Relay; url: string; headers = emptyHttpHeaders();
    body = ""; requestId = 0'i64; timeoutMs = 0): RequestResult
proc patch*(client: Relay; url: string; headers = emptyHttpHeaders();
    body = ""; requestId = 0'i64; timeoutMs = 0): RequestResult
proc delete*(client: Relay; url: string; headers = emptyHttpHeaders();
    requestId = 0'i64; timeoutMs = 0): RequestResult
proc head*(client: Relay; url: string; headers = emptyHttpHeaders();
    requestId = 0'i64; timeoutMs = 0): RequestResult
```

- `makeRequests` is blocking convenience API.
  - Requires an idle client (no queued/in-flight/undrained prior results).
- `makeRequest` is blocking single-request API.
  - Requires an idle client (same as `makeRequests`).
- `startRequests` is non-blocking enqueue API.
- `waitForResult` blocks until one result is available or worker stops.
- `pollForResult` returns immediately.

### Single Request APIs

`makeRequest` executes one `RequestSpec` and returns one `RequestResult`:

```nim
let single = client.makeRequest(RequestSpec(
  verb: hvPost,
  url: "https://example.com/api",
  headers: emptyHttpHeaders(),
  body: """{"x":1}""",
  requestId: 42,
  timeoutMs: 2_000
))
```

Client verb helpers (`client.get/post/put/patch/delete/head`) are convenience
wrappers around `makeRequest`.

### Queue / State Helpers

```nim
proc clearQueue*(client: Relay)
proc hasRequests*(client: Relay): bool
proc numInFlight*(client: Relay): int
proc queueLen*(client: Relay): int
```

- `clearQueue` cancels queued (not yet in-flight) requests.
- in-flight requests continue unless you call `abort`.

## Behavioral Notes

- Results are delivered in completion order, not submission order.
- Every request yields exactly one `RequestResult`.
- `Response.request.requestId` echoes the request id for correlation.
- Redirects are enabled by default (`maxRedirects`).
- Response body is automatically decoded when server uses gzip/deflate.

## Error Handling Pattern

```nim
for item in client.makeRequests(batch):
  if item.error.kind == teNone:
    # HTTP transport succeeded; still check status code policy in app layer.
    if item.response.code div 100 == 2:
      discard
    else:
      echo "http error status=", item.response.code
  else:
    echo "transport error kind=", item.error.kind, " msg=", item.error.message
```

## Examples

```bash
nim c -r examples/basic_get.nim
nim c -r examples/streaming.nim
```

## Tests

```bash
nimble test
```
