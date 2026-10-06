# WebSockets

Import `relay/websocket`. `WebSocketClient` owns persistent text/binary connections
and offers blocking and incremental operations on the same client, like `HttpClient`.
Connection IDs identify connections owned by that client; they own no resources.
See the [README example](../README.md#persistent-websockets) or
[runnable echo example](../examples/websocket_echo.nim).

Build with `--threads:on --mm:atomicArc` and a thread-safe, WebSocket-enabled
libcurl 8.14+ with matching headers.

## Blocking operations

```nim
proc connect*(client: WebSocketClient; url: sink string;
    timeoutMs = 0): WebSocketResult
proc send*(client: WebSocketClient; id: ConnectionId;
    message: sink WebSocketMessage; timeoutMs = 0): WebSocketResult
proc send*(client: WebSocketClient; id: ConnectionId;
    text: sink string; timeoutMs = 0): WebSocketResult
proc receive*(client: WebSocketClient; id: ConnectionId;
    timeoutMs = 0): WebSocketReceiveResult
proc closeConnection*(client: WebSocketClient; id: ConnectionId)
```

`connect` and `send` return the operation's `WebSocketResult`, preserving its transport
error kind, message and curl code. Check `error.kind == teNone` for success. Use a
connection ID only after successful connect. Failed blocking connects dispose their
retained state automatically, allowing another explicit attempt on the same client.

Blocking connect/send require an idle operation pipeline: no pending operations or
undrained completions. Open connections and buffered incoming messages do not make
it busy. The caller must have exclusive submission and result consumption access
throughout the call. The idle check does not reserve the pipeline against concurrent
callers, as with HTTP's blocking helpers. Other connections continue to progress in
the private worker. Send requires a successfully connected ID.

`WebSocketReceiveResult` has `kind`, `message` and `error`:

| Kind | Meaning |
| --- | --- |
| `wrMessage` | Owned text or binary message; `error.kind == teNone` |
| `wrClosed` | Terminal status in `error`, after queued messages |
| `wrTimedOut` | Receive deadline expired; `error.kind == teTimeout`; connection stays open |

Timeout is a caller outcome, not a connection event. Receive requires a known,
undrained ID. Use one receive/event consumer per connection. Consuming terminal status
releases that connection's slot.

`closeConnection` waits for a bounded close handshake, discards unread messages and
terminal status, and releases the connection's slot. Connecting operations are canceled
immediately. Accepted operation completions remain available; drain them before another
blocking connect/send. Other connections remain usable. Do not dispose a connection
concurrently with its receive/event consumer. The ID must be known and undrained.

## Client construction and incremental operations

```nim
proc newWebSocketClient*(maxConnections = 16; maxCommands = 64; maxEvents = 64;
    defaultTimeoutMs = 60_000; maxMessageBytes = 32 * 1024 * 1024;
    maxQueuedBytes = 32 * 1024 * 1024; closeTimeoutMs = 100;
    bypassProxy = false; proxy = ""; caInfo = ""): WebSocketClient
```

| Operation | Behavior |
| --- | --- |
| `startConnect(url, timeoutMs = 0)` | Returns connection and operation IDs |
| `startSend(id, message, timeoutMs = 0)` | Returns an operation ID; use after successful connect completion |
| `waitForResult(item)` / `pollForResult(item)` | Completions in completion order; wait blocks, poll returns immediately |
| `waitForEvent(id, item, timeoutMs = 0)` / `pollForEvent(id, item)` | Ordered messages, then one terminal event; wait blocks up to its timeout, poll returns immediately |
| `cancel(id)` / `startCloseConnection(id)` | Request cancellation / a bounded close handshake without waiting |
| `close()` / `abort()` | Join after bounded close handshakes / immediate cancellation |

- `WebSocketMessage`: `kind` (`wmText` or `wmBinary`) and owned `data: string`.
- `WebSocketResult`: `connectionId`, `operationId` and `error: TransportError`.
- `WebSocketEvent`: `connectionId`, `kind` (`weMessage` or `weClosed`), `message` and `error`.

Construction starts the private worker without opening a connection. Failed construction
releases acquired resources and propagates the exception. Each accepted operation
completes once. Curl parses URLs; malformed URLs, credentials
or schemes other than ws/wss fail the connect operation.
Check `error.kind == teNone` for success; peer/local close reports
`teCanceled`. Use one result consumer per client and one receive/event consumer
per connection. Submission and retrieval are synchronized while the worker is active.
Submission, cancellation and connection close require an open client. For all operations,
URLs must contain no NUL or fragments. Sent messages must fit `maxMessageBytes`, and
text must be valid UTF-8; sends do not validate it. All receivers must be non-nil
except for `close` and `abort`.
These are caller preconditions; assertions are disabled in danger builds.
Failed incremental connects retain a terminal event; consume it or call `closeConnection`
to release their slot. Cancellation and `startCloseConnection` preserve queued messages
followed by terminal status. Unknown IDs are ignored by those two control operations.
Retrieval returns false when no item is available after shutdown; an empty poll also
returns false. Event waits return false on timeout or unknown/drained IDs.

## Limits, timeouts and ownership

- `maxCommands` counts queued/active operations and undrained results. Full admission
  raises `IOError` without accepting work. Consume results to release capacity.
- `maxConnections` includes closed connections until their terminal events are consumed
  or they are disposed with `closeConnection`.
- `maxMessageBytes` bounds a message; `maxEvents` and `maxQueuedBytes` bound each event
  queue independently; choose both byte limits for the intended message sizes.
  Received message or event queue overflow closes that connection, preserving
  queued messages before its error.
- Nonpositive constructor limits clamp to one. Nonpositive timeout overrides use the default.
  Connect/send deadlines include queue time; an expired send closes its connection.
- An event-wait timeout returns false and leaves the worker connection open.
  Blocking `receive` returns `wrTimedOut`; neither execution style uses a timeout exception.
- Pass payloads normally to sink parameters. Nim moves them when it can prove last use;
  otherwise it copies them.
- Open client state and an idle pipeline for blocking connect/send are caller
  preconditions diagnosed with assertions, which are disabled in danger builds.
- A stopped worker or a connection that became unavailable refuses admission with
  `IOError`; these failures can occur while the owner is still open.
- Always call `close` or `abort` before releasing the final owner, using `try/finally`.
  Shutdown belongs to the creating thread after other callers finish. Repeated calls
  are safe; aliases share lifecycle state and destruction does not stop workers.
  Drain retained results/events on the creating thread after shutdown; `receive` can
  also drain retained messages and terminal status.
- Client `close` cancels connecting operations and performs bounded close handshakes
  for open connections before joining. Unfinished sends terminate as their connections
  close. `abort` cancels work and joins without waiting for close handshakes.
- A close handshake sends one CLOSE frame and uses a deadline set when closing begins;
  a peer reply does not restart it. Cancellation takes precedence over a close request.
- Transport handles, pending operations and frame buffers belong to the worker and
  are released when it removes the finished connection. Retained terminal events
  keep only shared receive queues and status alive.

TLS verifies trust and hostname. `proxy` overrides curl's environment proxy;
`bypassProxy` disables it. `caInfo` selects a CA file. Ping/close handling and received
UTF-8 validation are automatic. Redirects, URL credentials, extensions and subprotocols
are refused. Automatic reconnect, compression, custom headers and application callbacks are
not provided.

## Checks

```sh
nim test tests/ci.nims
sh tests/verify-websocket.sh
```

Uses local fixtures and requires Node.js and OpenSSL as development tools.
Linux/libcurl 8.18.0 is verified; other platforms/curl versions and proxy interoperability
remain unverified. `nim asan tests/ci.nims` covers ownership, worker failure and curl
initialization faults.
Adding `-d:threadInitFault` when compiling `tests/test_constructor_rollback.nim` also injects
thread creation failure; Nim 2.3.1 leaks runtime thread storage on that path.
