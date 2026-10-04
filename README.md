# relay

Relay provides HTTP and persistent WebSocket clients over libcurl. `HttpClient` handles
batches and single requests with bounded parallelism; `WebSocketClient` multiplexes
persistent connections, and `WebSocket` provides a synchronous text interface.

It gives you:

- bounded parallel HTTP work with queueing (`maxInFlight`)
- the same verb helpers for single calls and batches (`get`, `post`, `put`, `patch`, `delete`, `head`, `options`, `connect`, `trace`)
- two execution styles: blocking (`makeRequest`, `makeRequests`) or incremental draining (`startRequests` + `waitForResult`/`pollForResult`)
- operational controls for running pipelines (`queueLen`, `numInFlight`, `clearQueue`, `abort`)
- typed HTTP status codes with class classifiers (`HttpCode`, `is2xx`...)
- URL query parameter helpers (`QueryParams`)
- optional retry policy with backoff and jitter (`relay/retry`)

## Install
```bash
nimble install
```

## Quick Start (Blocking Batch)
```nim
import relay/http

let client = newHttpClient(maxInFlight = 8)
try:
  var batch: RequestBatch
  batch.get("https://example.com", requestId = 1)
  batch.get("https://example.org", requestId = 2)

  for item in client.makeRequests(batch):
    if item.error.kind == teNone:
      echo item.response.request.requestId, " status=", item.response.code
    else:
      echo item.response.request.requestId, " error=", item.error.kind,
        " ", item.error.message
finally:
  client.close()
```

## Quick Start (Blocking Single Request)
```nim
import relay/http

let client = newHttpClient()
try:
  let item = client.get("https://example.com", requestId = 7)
  if item.error.kind == teNone:
    echo item.response.request.requestId, " status=", item.response.code
  else:
    echo item.error.kind, " ", item.error.message
finally:
  client.close()
```

## Async Pattern (`startRequests` + drain)

Use this when your app has its own scheduling loop.
```nim
import relay/http

let client = newHttpClient(maxInFlight = 16)
try:
  var batch: RequestBatch
  batch.post("https://example.com/api", body = """{"x":1}""", requestId = 101)
  batch.post("https://example.com/api", body = """{"x":2}""", requestId = 102)

  # Capture size before startRequests(batch) drains the batch.
  var pending = batch.len
  client.startRequests(batch)
  while pending > 0:
    var item: RequestResult
    if client.waitForResult(item):
      dec pending
      if item.error.kind == teNone:
        echo item.response.request.requestId, " -> ", item.response.code
      else:
        echo item.response.request.requestId, " failed: ", item.error.message
finally:
  client.close()
```

## API Reference

Import `relay/http` for HTTP APIs.
Persistent connection APIs live in `relay/websocket`.

| Owner | Constructor | Purpose |
| --- | --- | --- |
| `HttpClient` | `newHttpClient` | HTTP request worker and batch/single-request helpers |
| `WebSocketClient` | `newWebSocketClient` | One worker for multiple persistent WebSocket connections |
| `WebSocket` | `newWebSocket` | Synchronous text interface for one WebSocket connection |

`connect` on `HttpClient` issues HTTP CONNECT; on `WebSocket` it opens a persistent
connection. See [WebSockets](docs/WEBSOCKETS.md) for the worker API.

### Modules

| Module | Responsibility |
| --- | --- |
| `relay/bindings/curl` | C declarations for curl handles, HTTP and WebSockets |
| `relay/curl_wrap` | Owned handles, checked options and curl operations |
| `relay/transport_errors` | Transport error construction, classification and retry predicates |
| `relay/http` | HTTP worker, requests, batches and completions |
| `relay/websocket` | Multi-connection worker and synchronous text connection |

### Core Types

- `HttpHeaders = seq[tuple[name: string, value: string]]`
- `HttpVerb = enum hvGet = "GET", hvPost = "POST", hvPut = "PUT", hvPatch = "PATCH", hvDelete = "DELETE", hvHead = "HEAD", hvOptions = "OPTIONS", hvConnect = "CONNECT", hvTrace = "TRACE"`
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

### Status, Query, and Retry Helpers

`import relay/http` exports the following helpers from its submodules:
```nim
# relay/http_status: typed status codes and classifiers
HttpCode, Http200..Http511, is1xx..is5xx, `$` # "404 Not Found"

# relay/http_query: URL query parameters
QueryParams, encodeQueryComponent, decodeQueryComponent

# relay/retry: optional retry policy
RetryPolicy, initRetryPolicy, backoffBaseMs, retryDelayMs,
isRetryable
```

`Response.code` is an `HttpCode`; classify it directly:
```nim
if is2xx(item.response.code):
  discard
echo $item.response.code # "200 OK"
```

### Client Lifecycle
```nim
proc newHttpClient*(maxInFlight = 16; defaultTimeoutMs = 60_000;
    maxRedirects = 10): HttpClient
proc close*(client: HttpClient)
proc abort*(client: HttpClient)
```

- `newHttpClient` starts HttpClient’s internal worker thread.
- `close` waits for queued/in-flight work to finish, then shuts down cleanly.
- `abort` cancels pending/in-flight work and stops quickly.

### Threading & Lifecycle Constraints

- Build with `--threads:on --mm:atomicArc`; `tests/config.nims` sets these for tests.
  Use a thread-safe libcurl build with matching headers. WebSockets require 8.14+.
  These are build requirements; clients do not probe versions or memory models.
- HttpClient ownership: treat a `HttpClient` instance as single-owner from the creating
  thread.
- `close` / `abort`: call from the same thread that created the `HttpClient`; do not
  invoke them concurrently with other client calls. Finish other callers before shutdown.
- Drain HTTP results and make queries before shutdown. Afterwards, only repeated
  `close` / `abort` calls are supported.
- Each client pairs curl initialization with cleanup after releasing its handles.
  Libcurl supplies the counting and synchronization. HTTP and WebSocket workers
  can coexist and close in either order.
- Aliases retain shared lifecycle state; repeated close/abort calls are safe.
  Call `close` or `abort` before releasing the final owner, using `try/finally`.
  Destruction does not stop workers.

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
proc startRequest*(client: HttpClient; request: sink RequestSpec)
proc startRequests*(client: HttpClient; batch: var RequestBatch)
proc waitForResult*(client: HttpClient; outResult: var RequestResult): bool
proc pollForResult*(client: HttpClient; outResult: var RequestResult): bool
proc makeRequests*(client: HttpClient; batch: var RequestBatch): RequestResults
proc makeRequest*(client: HttpClient; request: sink RequestSpec): RequestResult
proc get*(client: HttpClient; url: string; headers = emptyHttpHeaders();
    requestId = 0'i64; timeoutMs = 0): RequestResult
proc post*(client: HttpClient; url: string; headers = emptyHttpHeaders();
    body = ""; requestId = 0'i64; timeoutMs = 0): RequestResult
proc put*(client: HttpClient; url: string; headers = emptyHttpHeaders();
    body = ""; requestId = 0'i64; timeoutMs = 0): RequestResult
proc patch*(client: HttpClient; url: string; headers = emptyHttpHeaders();
    body = ""; requestId = 0'i64; timeoutMs = 0): RequestResult
proc delete*(client: HttpClient; url: string; headers = emptyHttpHeaders();
    requestId = 0'i64; timeoutMs = 0): RequestResult
proc head*(client: HttpClient; url: string; headers = emptyHttpHeaders();
    requestId = 0'i64; timeoutMs = 0): RequestResult
```

- `startRequest` is non-blocking enqueue API for a single request.
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
proc clearQueue*(client: HttpClient)
proc hasRequests*(client: HttpClient): bool
proc numInFlight*(client: HttpClient): int
proc queueLen*(client: HttpClient): int
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
    if is2xx(item.response.code):
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
nim test tests/ci.nims
```

## Persistent WebSockets

Use `WebSocket` for blocking text messages:
```nim
import relay/websocket

let socket = newWebSocket()
try:
  socket.connect("wss://example.com/socket")
  socket.send("hello")
  echo socket.receive()
finally:
  socket.close()
```

For multiple connections or binary messages, use `WebSocketClient`. Both clients can
run alongside HTTP. See [WebSockets](docs/WEBSOCKETS.md) for limits, timeouts and lifecycle.

Local WebSocket checks require Node.js and OpenSSL:
```sh
sh tests/verify-websocket.sh
```
