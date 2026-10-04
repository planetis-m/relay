# Persistent WebSockets

`relay/websocket` transports messages without JSON or application callbacks. One
`WebSocketService` owns one worker for multiple connections; HTTP retains its separate
worker. Build with `--threads:on --mm:atomicArc` and a WebSocket-enabled libcurl 8.14+
with matching development headers. Linux/libcurl 8.18.0 is verified.

## Minimal public API

| API | Contract |
| --- | --- |
| `newWebSocketService(maxConnections = 16, maxCommands = 64, maxEvents = 64, defaultTimeoutMs = 60_000, maxMessageBytes = 32 * 1024 * 1024, maxQueuedBytes = 32 * 1024 * 1024, closeTimeoutMs = 100, bypassProxy = false, proxy = "", caInfo = "")` | Starts one worker; nonpositive bounds clamp to one |
| `startConnect(url: sink string, timeoutMs = 0)` | Returns distinct connection and operation IDs |
| `startSend(id, message: sink WebSocketMessage, timeoutMs = 0)` | Returns an operation ID; use after successful connect completion |
| `waitForResult(item: var WebSocketResult)` / `pollForResult(item)` | Completion order, correlated by operation ID; false after worker stops and results drain |
| `waitForEvent(id, item: var WebSocketEvent, timeoutMs = 0)` / `pollForEvent(id, item)` | Per-connection ordered messages, then one terminal event; false on wait timeout or unknown/drained ID |
| `cancel(id)` | Immediately requests cancellation, bypassing command capacity |
| `closeConnection(id)` | Requests a bounded close handshake, bypassing command capacity |
| `close()` / `abort()` | Join after bounded handshakes / cancellation; retained events and results remain drainable |

`WebSocketMessage` has `kind: wmText | wmBinary` and owned `data: string` (arbitrary
bytes for binary). `WebSocketResult` has `connectionId`, `operationId` and Relay's
`TransportError`. `WebSocketEvent` has `connectionId`, `kind: weMessage | weClosed`,
`message` and `error`. Peer/local close is a terminal cancellation reason; receive
and protocol failures have an explicit error. Accepted operations complete exactly
once; cancellation does not erase results. There are no retry/reconnect semantics.

Submission/retrieval is synchronized. Use one result consumer and one event consumer
per connection to preserve application ordering. Lifecycle calls must run on the
creating thread, without concurrent lifecycle calls, matching Relay. Aliases share
close state. Dropping the final owner aborts and joins before locks/queues are freed;
worker threads borrow owner pointers and do not retain their own owner. Lifecycle
objects use `byref` so destruction never copies synchronization primitives.

The text-only `newWebSocket(defaultTimeoutMs = 60_000, maxMessageBytes = 32 * 1024 * 1024,
bypassProxy = false)` convenience owner exposes blocking `connect`, `send`, `receive`
and `close`, using one service/connection. It raises `TimeoutError` (an `IOError`) for
deadline expiry and `IOError` for transport/protocol errors, closing on those failures.
Invalid caller URLs/text/size or repeated connect raise `ValueError` and preserve the
existing connection. This convenience API has one caller and is not reentrant.

## Ownership, limits and deadlines

All easy/multi handles, headers, upgrade state, partial writes and reassembly buffers
belong exclusively to the worker. The sole cross-thread curl call is the documented
`curl_multi_wakeup` operation, under the owner lock while its handle remains alive.
Commands and payloads transfer through locked queues with atomic ARC. No caller buffer
is borrowed by the worker. Results/events transfer back through the same boundary.
The worker never calls an application callback.

`maxCommands` bounds queued commands + active operations + undrained results. Full
admission raises `IOError` without accepting an operation. Payloads are bounded by
`maxMessageBytes`, hence admitted command payload storage is at most their product.
`maxConnections` includes terminal mailboxes until their terminal events are drained.
Each mailbox has at most `maxEvents` messages and `maxQueuedBytes` payload bytes plus
one reserved terminal error. Overflow fails that connection immediately, preserves
already accepted messages and reports the overflow after them. It cannot block control
traffic on other connections. Partial incoming data is capped by `maxMessageBytes`.
Each connection has at most eight pending control replies; control flood fails it.
Final owner destruction discards intentionally abandoned retained results/events.

Connect/send deadlines start at submission and include queue time. Any expired send
fails the connection, including a short deadline queued behind a blocked long send.
Nonpositive overrides use `defaultTimeoutMs`; positive timeouts clamp to `cint.high`.
An event wait has its own monotonic deadline and does not close a general connection
on timeout. The text convenience owner closes on receive timeout. Progress, fragments
and ping traffic never renew deadlines. The worker bounds each turn to four 16 KiB
receive chunks, one 16 KiB outgoing data chunk, and one control write per connection.
Polling revisits deadlines within 20 ms plus scheduler/curl-call time; commands and
cancellation wake polling immediately. Buffered frames are revisited on subsequent
turns even when kernel readability does not reflect curl's buffered data.

Close completes a handshake when the peer answers, otherwise tears down at
`closeTimeoutMs`. A partly sent frame must finish before a control frame can be sent;
the close deadline still bounds teardown. Abort/cancel discard partial I/O and do not
wait for peers or consumer capacity. Waiters are broadcast on completions, terminal
state, shutdown and deadline ticks. Handles remain attached to their multi owner
through connect-only use, then are removed/destroyed before global cleanup.

## Protocol and shared mechanics

TLS verifies trust and hostname. Proxy defaults use curl's environment; `proxy` selects
an explicit proxy and `bypassProxy` takes precedence. `caInfo` selects a CA file without
disabling TLS checks. Redirects, credentials, fragments, unsolicited extensions and
subprotocols are refused. A unique `Sec-WebSocket-Accept` is checked against the client
nonce. Text UTF-8 is validated after fragment reassembly; binary is represented
explicitly. Ping payloads are echoed even while callers are idle. Close payload length,
code and reason UTF-8 are validated. Libcurl owns masking and wire framing.

HTTP and WebSockets share curl wrappers, synchronized counted global init/cleanup,
transport errors/classification and the wrapper wakeup primitive. Easy's move hook
clears moved-from storage before moving its error buffer; failed slist append preserves
the prior owner. HTTP public request APIs/defaults remain compatible. HTTP's queues
retain their previous behavior; WebSocket limits do not impose a new HTTP queue policy.
No generic executor/worker framework is introduced.

Official curl contracts consulted: [connect-only lifetime](https://curl.se/libcurl/c/CURLOPT_CONNECT_ONLY.html),
[partial sends](https://curl.se/libcurl/c/curl_ws_send.html),
[receive metadata and fragments](https://curl.se/libcurl/c/curl_ws_recv.html),
[wakeup](https://curl.se/libcurl/c/curl_multi_wakeup.html) and
[global initialization](https://curl.se/libcurl/c/curl_global_init.html).
Declarations are verified against supported curl headers and C ABI probes.

## Verification and deliberate limits

The standalone `tests/verify-websocket.sh` runs unit/ABI/ownership contracts and 18
independent loopback worker groups in debug/release/danger. Fixtures cover two sockets
plus HTTP, independent shutdown in both orders, idle ping/close, fragments/control
traffic during sends, resumed writes, blocked-peer fairness, binary, payload mutation, count/byte queue
pressure, queue-time deadlines, connect/send/receive cancellation, full-queue shutdown,
failure recovery, aliases/final-owner destruction and trusted/untrusted/hostname WSS.

No compression, subprotocol negotiation, configurable request headers, authentication,
reconnect, application callbacks, configurable close codes or initiated heartbeat API
is supplied. Incoming ping/close handling is supported. Proxy configuration is exposed;
an independent proxy server/interoperability matrix is not verified. Other operating
systems, other supported curl versions, allocation/thread-start fault injection and
unusual TLS backends remain unverified. Correctness fixtures are not benchmarks.
