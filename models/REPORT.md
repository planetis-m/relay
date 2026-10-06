# Validation report

No confirmed supported-API runtime defect was found. Required safety invariants and
bounded liveness goals pass under the stated caller and fairness assumptions.
The [README](README.md) gives the models, bounds and direct commands.

## Model results

Validation used `tlanif` from PATH with a 400,000-state cap. Reference and four-worker
safety checks agree. Compiled and reference liveness checks agree on results and graph
counts; required goals are nonvacuous and every reachable state has a fair continuation
under the selected assumptions.

| Scenario | States | Safety and required liveness |
| --- | ---: | --- |
| WebSocket lifecycle, default | 91,346 | Pass |
| WebSocket frames/close | 58,180 | Pass |
| WebSocket reuse | 213,205 | Pass |
| WebSocket duplex | 166,938 | Pass |
| HTTP, one handle and one waiter | 5,859 | Pass |
| HTTP, two handles and one waiter | 7,803 | Pass |
| HTTP, one handle and two waiters | 10,757 | Pass |
| HTTP, two handles and two waiters | 14,205 | Pass |

Safety covers at-most-once completion, queue/result accounting, private handle
ownership, terminal delivery, stopped cleanup and final waiter wakeups. Frame checks
also cover message/byte/control limits, partial-write exclusion and close deadlines.

Liveness covers requested worker shutdown, connection close/cancel completion,
operation publication/consumption, event/disposal waits and individual HTTP result
callers. Worker and deadline fairness establish shutdown/publication independently
of consumers. Consumption adds caller fairness; HTTP owner discard adds join fairness.
Send/close timeout checks require no peer cooperation or successful transmission.

The largest two-waiter check completed in **0.36 seconds** using approximately
**23 MiB** peak memory. This is one local compiled release measurement, excluding
compilation. An unrestricted two-connection WebSocket exploration exceeded the cap
and remains incomplete; only the documented reduced variants are validated.

## Findings

**HTTP abort can discard unpublished queued work.** A submission can race the
worker's empty snapshot and owner abort. The worker can then leave
[waitForWorkOrClose](../src/relay/http.nim:213) without publishing that request;
owner join discards it. This matches the shutdown contract: other callers finish
before owner shutdown, which also discards unread results. The diagnostic
`StrictCompletionInv` fails because it requires a stronger publication promise.
Graceful shutdown and unexpected worker failure still require all accepted completions.

**Concurrent HTTP retrieval shares one FIFO.** Each completion signals one sleeper;
worker exit broadcasts. A signal reserves no result, so another caller may consume it
before the awakened caller rechecks. An empty wait may then legitimately continue.
Blocking convenience helpers still require exclusive access. HTTP `numInFlight`
includes private configuration/finalization, not just the in-flight table;
`clearQueue` leaves active work alone. Caller `requestId` values need not be unique,
and transfer completion can reverse admission order.

**Waiter progress needs individual goals and fairness.** With two callers,
`[]<>(all callers idle)` can fail while each caller repeatedly returns, because their
next calls overlap. Aggregate consumer fairness can also permit one caller to starve
while the other keeps running. Separate goals and fairness groups pass. These are
modeling and scheduling distinctions, with no runtime defect established.

**WebSocket cancel does not retract work already running.** The worker reads the
mailbox request before servicing outside the lock. A later cancel can coexist with
a send completion; it takes effect on a subsequent observation. Cancel overrides
close. A terminal mailbox can also be disposed while a targeting command remains
in the shared/detached queue; that command later completes independently. HTTP drops
results on owner join, while WebSocket retains results/events.

**Reachability checks exercise the intended races.** Probes reached budget exhaustion,
connection reuse, cancellation isolation, out-of-order HTTP transfers, two sleeping
or awakened result callers, and consumption of another caller's signaled result.
Checked invariants exclude duplicate completion/terminal delivery, stopped sleeping
waiters, unarmed close deadlines and overlapping partial data/control writes.
One handle cannot reverse two simultaneous transfers; the two-handle variant can.
The WebSocket worker's `cnFinished` service arm is unreachable at its current guarded
call site and is defensive. Lifecycle PC 3 is reserved bookkeeping.

**The apparent duplicate state serves different roles.** Outstanding work and queued
bytes are cached accounting checked against their contents. Worker-stopped versus
owner-joined, retained mailbox versus connection phase, and private handle ownership
versus table registration must remain distinct. Publication/history counters and
owner-abort provenance are model instrumentation.

Negative controls fail as expected: shutdown without scheduling fairness, close
without deadline progress, unconditional empty-result waiter return, aggregate
fairness for two callers, and simultaneous waiter idleness. A small state cap reports
incomplete. Tlanif reference-validates the emitted fair counterexamples.

## Runtime checks

[test_websocket_protocol.nim](../tests/test_websocket_protocol.nim) covers text/binary
and empty messages, a 48 KiB send, fragmented reception with PING/PONG, receive
timeouts, message-before-terminal ordering, retained events, bounded close without
a peer reply, full-budget abort/cancel, duplicate-delivery exclusion and invalid UTF-8.
It also creates two clients on separate owner threads. Both exchange distinct messages;
one aborts and releases its libcurl reference while the other remains connected,
then the survivor exchanges another message and closes gracefully.

[test_lifecycle_contracts.nim](../tests/test_lifecycle_contracts.nim) checks two raw
HTTP result waiters sharing a client. Two timed-out loopback transfers produce one
distinct completion per caller, with no residual outstanding work or ready result.
Owner shutdown follows both caller joins.

Both changed test programs passed default, release, danger and AddressSanitizer
builds with threads and atomicArc on WebSocket-enabled libcurl 8.18.0. The full
14-program default suite passed before the concurrency additions; only the changed
programs were rerun afterwards. TSan was not run. WebSocket protocol tests explicitly
skip when the linked libcurl lacks the required support.

## Limits

These results support the documented usage within finite bounds and explicit
fairness assumptions. Coverage includes two connections within one WebSocket client,
two independent WebSocket client instances at runtime, and at most two HTTP result
callers. It does not establish arbitrary client/caller counts, unbounded workloads,
wall-clock guarantees, complete memory safety, constructor rollback, byte parsing,
TLS or retry correctness. No production worker change was needed.
