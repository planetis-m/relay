# WebSockets

Import `relay/websocket`. Use `WebSocket` for blocking text messages or
`WebSocketClient` for multiple connections with text and binary messages.
Both can run alongside `HttpClient`. See the [README example](README.md#persistent-websockets).

Build with `--threads:on --mm:atomicArc` and a thread-safe, WebSocket-enabled
libcurl 8.14+ with matching headers.

## Blocking text

```nim
proc newWebSocket*(defaultTimeoutMs = 60_000; maxMessageBytes = 32 * 1024 * 1024;
    bypassProxy = false): WebSocket
proc connect*(client: WebSocket; url: string; timeoutMs = 0)
proc send*(client: WebSocket; text: string; timeoutMs = 0)
proc receive*(client: WebSocket; timeoutMs = 0): string
proc close*(client: WebSocket)
```

Malformed URLs, credentials and transport/protocol failures raise `IOError`; deadline expiry raises
`TimeoutError`, an `IOError`. Errors propagate without joining the worker: call `close`
in `finally`. A receive timeout leaves the connection open. Use one caller per `WebSocket`.
After a failed connect, close the client and use a new one for another attempt.
Connect requires an open, disconnected client; send/receive require a connected client.
These are asserted preconditions; assertions are disabled in danger builds.

## Connection worker

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
| `cancel(id)` / `closeConnection(id)` | Request cancellation / a bounded close handshake without waiting |
| `close()` / `abort()` | Join after bounded close handshakes / immediate cancellation |

- `WebSocketMessage`: `kind` (`wmText` or `wmBinary`) and owned `data: string`.
- `WebSocketResult`: `connectionId`, `operationId` and `error: TransportError`.
- `WebSocketEvent`: `connectionId`, `kind` (`weMessage` or `weClosed`), `message` and `error`.

Each accepted operation completes once. Curl parses URLs; malformed URLs, credentials
or schemes other than ws/wss fail the connect operation.
Check `error.kind == teNone` for success; peer/local close reports
`teCanceled`. Use one result consumer and one event consumer
per connection. Submission and retrieval are synchronized while the worker is active.
Submission, cancellation and connection close require an open client. For both APIs,
URLs must contain no NUL or fragments. Sent messages must fit `maxMessageBytes`, and
text must be valid UTF-8. All receivers must be non-nil except for `close` and `abort`.
These are caller preconditions; assertions are disabled in danger builds.
Retrieval returns false when no item is available after shutdown; an empty poll also
returns false. Event waits return false on timeout or unknown/drained IDs.

## Limits, timeouts and ownership

- `maxCommands` counts queued/active operations and undrained results. Full admission
  raises `IOError` without accepting work. Consume results to release capacity.
- `maxConnections` includes closed connections until their terminal events are consumed.
- `maxMessageBytes` bounds a message; `maxEvents` and `maxQueuedBytes` bound each event
  queue. Received message or event queue overflow closes that connection, preserving
  queued messages before its error.
- Nonpositive constructor limits clamp to one. Nonpositive timeout overrides use the default.
  Connect/send deadlines include queue time; an expired send closes its connection.
- An event-wait timeout returns false and leaves the worker connection open.
  Blocking `WebSocket.receive` raises `TimeoutError` and leaves the connection open.
- Always call `close` or `abort` before releasing the final owner, using `try/finally`.
  Shutdown belongs to the creating thread after other callers finish. Repeated calls
  are safe; destruction does not stop workers. Drain retained worker results/events
  on the creating thread after shutdown.

TLS verifies trust and hostname. `proxy` overrides curl's environment proxy;
`bypassProxy` disables it. `caInfo` selects a CA file. Ping/close handling and received
UTF-8 validation are automatic. Redirects, URL credentials, extensions and subprotocols
are refused. Reconnect, compression, custom headers and application callbacks are
not provided.

## Checks

```sh
sh tests/verify-websocket.sh
```

Uses local fixtures and requires Node.js and OpenSSL as development tools.
Linux/libcurl 8.18.0 is verified; other platforms/curl versions and proxy interoperability
remain unverified. `nim asan tests/ci.nims` covers ownership and curl initialization faults.
Adding `-d:threadInitFault` when compiling `tests/test_constructor_rollback.nim` also injects
thread creation failure; Nim 2.3.1 leaks runtime thread storage on that path.
