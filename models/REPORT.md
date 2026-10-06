No supported-API defect was established. HTTP and WebSocket's checked properties
have no violation within the stated finite bounds. HTTP owner abort can skip internal
completion publication, which is permitted by its clarified shutdown contract.
Direct safety and native bounded liveness results are recorded below. Required
progress goals pass under explicit weak fairness; the safety CLI alone does not
prove eventual progress.
The [README](README.md) defines bounds, atomicity and fairness.

Implementation observations below are **TRACED** from source and model interleavings.
The loopback tests described at the end exercise actual WebSocket transport behavior;
they do not reproduce HTTP's specific abort schedule. Models do not establish memory safety.
Reviewed fingerprints are recorded below; changed source requires retracing the
models and findings. No production code is modified.

HTTP's owner-abort discard follows this legal schedule in
[http.nim](../src/relay/http.nim:214):

| Step | Worker / caller action | Consequence |
| --- | --- | --- |
| 0 | Initial running worker, empty queue/table | One easy handle available |
| 1 | dispatchQueuedRequests finds no queued work and returns | Nothing dispatched |
| 2 | Caller completes startRequest | Request queued, outstanding incremented |
| 3 | Worker captures hasInflight=false, shouldAbort=false | Queue is not part of snapshot |
| 4 | Owner calls abort after submission returns | State becomes aborting; worker awakened |
| 5 | Worker takes previously selected waitForWorkOrClose branch | Uses captured no-inflight value |
| 6 | waitForWorkOrClose sees aborting and returns false | Breaks without flushFailedLocked |
| 7 | Worker publishes stopped and broadcasts | Accepted request queued without completion |

Both Tlanif evaluators produce an eight-state shortest trace when checking the diagnostic
StrictCompletionInv, which demands publication even during owner abort. Owner join
subsequently resets queue and outstanding, discarding that request. Worker shutdown
completes; no result waiter exists in this counterexample.

The production impact is limited by the HTTP shutdown contract: other callers must
finish before abort, unread results are discarded on join, and result retrieval after
join is unsupported. Thus this trace does not demonstrate a user-visible lost result,
hang or resource leak under supported use. Its internal publication difference is
insignificant to the supported API; the worker was left unchanged. The root README now
explicitly exempts owner-aborted work from its previously unqualified completion promise.

The ordinary workerMain abort branch flushes; the waitForWorkOrClose abort branch does
not. An idle worker can also be signalled by submission and aborted before rechecking
its wait predicate. The default invariant permits unpublished work only when ghost
ownerAbort records owner cancellation. Graceful shutdown and unexpected worker failure
must publish all accepted completions before stopping. At-most-once publication,
accounting, resource release and wakeup checks remain intact. Discarded work is a
terminal outcome in the progress goals, not a delivery-progress failure.

HTTP [shutdown](../src/relay/http.nim:288) discards unread results and destroys
synchronization after join. This is documented: drain/query before shutdown; afterwards
only repeated close/abort are supported. The model allows discard of already-published
results and owner-aborted unpublished requests. WebSocket retains
results/events after join; a common post-close retrieval model would be incorrect.

HTTP [numInFlight](../src/relay/http.nim:323) uses outstanding minus ready results minus
queue length. It includes private setup/finalization where a request is in neither queue
nor in-flight table. Equating it with table length incorrectly rejects valid behavior.
Pool conservation also counts private ownership. [clearQueue](../src/relay/http.nim:334)
leaves active objects alone and publishes cancellations without decrementing outstanding.

HTTP requestId is caller-supplied and defaults to zero, with no uniqueness guarantee.
Model object identities remain distinct even with repeated correlation IDs. Transfer
completion can reverse admission with two handles; clearing queued work can publish a
later request before an earlier active request with one handle. Neither promises
submission ordering.

HTTP [configureEasy](../src/relay/http.nim:107) sets the curl timeout after queue removal;
queue waiting is outside transfer timeout. WebSocket connect/send deadlines include
queue time, so the shared timeoutMs spelling should not imply identical semantics.
HTTP abort can arrive during configuration/finalization without retracting that step.
Conservation is checked; the models do not promise all such results have canceled error
kind. The outer worker catches IOError, not arbitrary Defects/memory faults.

HTTP blocking helpers check idle state without reserving exclusive access. Concurrent
submission/consumption can violate their result-count assumptions; exclusivity is a
modeled caller constraint. WebSocket explicitly documents one result consumer. HTTP raw
waitForResult/pollForResult callers compete for one FIFO under the client lock;
signals do not reserve results for a caller. The two-waiter model and runtime check
below cover this behavior. A caller can remain waiting if its competitor consumes
all available results; neither FIFO distribution among callers nor per-request ownership
is promised by these retrieval functions.

WebSocket cancellation is **TRACED** in
[serviceConnection](../src/relay/websocket.nim:347) and
[cancel](../src/relay/websocket.nim:559). The worker captures mailbox.request under
lock, then operates outside it. A later cancel can coexist with send completion; the
next turn observes it. Cancel precedence prevents later close from replacing cancel,
but does not retract running frame work. WitnessCancelAfterRead alone does not prove
temporal ordering/error kind; the source's separated read/service/store permits it.

WebSocket terminal disposal is **TRACED** in
[finish](../src/relay/websocket.nim:113),
[processCommands](../src/relay/websocket.nim:292) and
[retrieval](../src/relay/websocket.nim:597). Finish completes its owned connect/send FIFO
before terminal publication. A send admitted to the shared queue after batch detachment
can remain pending when its mailbox finishes and is disposed. The worker later completes
that command as unavailable/canceled. Terminal delivery cannot imply that all shared
commands targeting that ID have completed. Results have independent lifetime/budget.

Expected reachable WebSocket states include finished retained mailboxes, stopped workers
with unread results, and removed mailboxes still represented by finished worker objects
before sweep. CLOSE can wait behind partial data/control writes; expiry finishes without
peer reply. Peer/local CLOSE flags are independent. Empty fragment assembly can coexist
with queued PONG. Empty messages fill event capacity without byte capacity; one message
can fill byte capacity with an event slot spare. Duplex exercises cancellation isolation.
Required nonvacuity probes protect these paths.

WebSocket absent probes include stopped-with-unpublished-work, terminal delivered twice,
closing without a deadline, and overlapping partial data/control frames. Exclusions depend
on caller constraints. One source arm is **TRACED** as unreachable at its current call site:
[serviceConnection's cnFinished arm](../src/relay/websocket.nim:384). The worker checks
phase before calling and is its sole writer. This is defensive, not a demonstrated defect.
Unavailable-send processing remains necessary when closure races queued dispatch.

Other absent probes follow bounds. Lifecycle's single connection cannot hold two mailboxes
or fill budget two after connect consumption; reuse/duplex supply budget-full coverage.
Duplex starts after connects and disables terminal consumption; its upgrade/disposal
paths are absent. Lifecycle PC 3 is reserved bookkeeping. One HTTP handle cannot register
two transfers or reverse simultaneous transfer completion; two handles supply those probes.
HTTP stopped-pending is reachable only under owner abort's allowed discard. An absent probe alone
is not evidence of a dead source branch.

Cached derived state is intentional: outstanding counts accepted work minus consumed
results (with HTTP's explicit owner reset); WebSocket queuedBytes sums message lengths.
Conservation protects both. Worker-stopped versus owner-closed, retention versus phase,
frame-started versus offset, and incoming-active versus bytes are necessary distinctions.
HTTP handle ownership differs from table registration. Stage/publication/history,
owner-abort provenance and deadline/delivery counters are ghost instrumentation. Disabling events/waiters in a
reduced scenario leaves their maps equal to zero; this does not justify deleting
implementation fields.

Limits include finite identities, abstract failures, no curl/OS proof, ARC safety,
constructor rollback, byte parsing, TLS, retry correctness, exact error kinds, more than
two HTTP waiters or wall-clock guarantees. Progress relies on stated fairness: an unscheduled
worker, nonadvancing transfer deadline or unwilling consumer can stall independently.

Initial safety validation on 2026-10-06 used `tlanif` from PATH, with source audited at
`d62f987771ee4899ce0ad3cafc73679e8a2e941a`. The six exhaustive passing scenarios were
also rerun with the native-feature build at `741bff8`. Counts below agree between
sequential-reference and `--jobs:4` compiled-parallel exploration, with cap 400,000:

| Specification / variation | Safety result | States |
| --- | --- | ---: |
| WebSocket lifecycle, default | Pass, including stopped-waiter wakeup invariant | 91,346 |
| WebSocket frames/close | Pass | 58,180 |
| WebSocket reuse, restrictions in README | Pass | 213,205 |
| WebSocket duplex, restrictions in README | Pass | 166,938 |
| HTTP default lifecycle invariant, one handle | Pass, including owner-abort exception | 5,859 |
| HTTP default lifecycle invariant, two handles | Pass, including owner-abort exception | 7,803 |
| HTTP two result waiters, one handle | Pass, including final broadcast to both callers | 10,757 |
| HTTP two result waiters, two handles | Pass, including final broadcast to both callers | 14,205 |
| HTTP diagnostic StrictCompletionInv | Fails stronger-than-contract abort policy | 8-state shortest counterexample |

Direct reachability checks used `(check (not WitnessName.0.))`. Their expected
counterexamples show reachability, not implementation failures:

| Probe | Bounds | Sequential / parallel result |
| --- | --- | --- |
| WitnessBudgetFull | Two fresh WebSocket IDs, one slot | Reachable, 14-state trace; first terminal consumed while its result remains, second connect admitted |
| WitnessIsolation | Reduced duplex variation | Reachable, 15-state trace; canceled connection finished, another open with send completion |
| WitnessTransferOutOfOrder | HTTP one handle | Absent, all 5,859 states explored |
| WitnessTransferOutOfOrder | HTTP two handles | Reachable, 13-state trace; second request finalizing while first remains in flight |
| WitnessUnexpectedStoppedPending | HTTP one handle | Absent, all 5,859 states explored; no unpublished work at stop without owner abort |
| WitnessTwoWaitersAsleep | HTTP two waiters, one handle | Reachable, 3-state trace; both wait on the shared result condition |
| WitnessTwoWaitersAwake | HTTP two waiters, one handle | Reachable, 5-state trace |
| WitnessStolenResult | HTTP two waiters, one handle | Reachable, 5-state trace; another consumer takes the signaled result before the awakened caller rechecks |

An unrestricted two-connection WebSocket witness exploration exceeded the 400,000-state
cap and is **incomplete**. It supplies no verification claim. The documented reduced
variations completed. No temporal liveness claim is derived from these safety runs.
Final broadcast is checked as a safety condition: stopped state must not retain an
asleep waiter. Eventual execution of awakened callers still needs scheduler fairness.

Native liveness validation on 2026-10-06 used a release build of Tlanif commit
`741bff8`, available as `tlanif` in PATH. Its freshly compiled native
regression suite passed fixtures, 120 independent fairness-oracle graphs, deep SCCs,
witness checks, CLI outcomes and reference/four-worker safety agreement. No external
graph checker or result parser was used. The old safety-only checker at `d62f987`
could not establish eventual progress; the new native mode closes that gap.

Both native evaluators completed every following graph at cap 400,000 with the same
state/edge counts and passing goals. Every run also checked the safety invariant.
Edges are unique full-state transitions, including implicit stuttering at every state.
No selected goal was reported vacuous, and no state lacked a fair continuation.

| Specification / variation | States | Edges | Progress goals passed |
| --- | ---: | ---: | --- |
| WebSocket lifecycle, default | 91,346 | 429,469 | GoalShutdown, GoalTerminal, GoalPublished, GoalCompletions, GoalResultWait, GoalEventWait |
| WebSocket reuse | 213,205 | 856,973 | GoalShutdown, GoalTerminal, GoalPublished, GoalCompletions |
| WebSocket duplex | 166,938 | 599,579 | GoalShutdown, GoalTerminal, GoalPublished, GoalCompletions |
| WebSocket frames/close | 58,180 | 337,514 | GoalClose, GoalSends |
| HTTP, one handle, one waiter | 5,859 | 19,184 | GoalShutdown, GoalDelivery, GoalOperations, GoalResultWait |
| HTTP, two handles, one waiter | 7,803 | 25,904 | GoalShutdown, GoalDelivery, GoalOperations, GoalResultWait |
| HTTP, one handle, two waiters | 10,757 | 42,829 | GoalShutdown, GoalDelivery, GoalOperations, GoalResultWait1, GoalResultWait2 |
| HTTP, two handles, two waiters | 14,205 | 56,421 | GoalShutdown, GoalDelivery, GoalOperations, GoalResultWait1, GoalResultWait2 |

Fairness was selected separately for different guarantees; assuming consumers run
was not used to establish shutdown or publication:

| Goals | Selected weak-fairness groups |
| --- | --- |
| WebSocket GoalShutdown, GoalTerminal, GoalPublished | FairWorker, FairDue |
| WebSocket GoalCompletions, GoalResultWait | FairWorker, FairDue, FairResult |
| WebSocket GoalEventWait, default only | FairWorker, FairDue, FairEvent, FairWaitClock |
| Frames GoalClose | FairCancel, FairClose, FairClock, FairFinish |
| Frames GoalSends | FairSendClock |
| HTTP GoalShutdown, GoalDelivery | FairWorker, FairNetwork |
| HTTP GoalOperations, one waiter | FairWorker, FairNetwork, FairConsumer, FairOwner |
| HTTP GoalResultWait, one waiter, either handle bound | FairWorker, FairNetwork, FairConsumer |
| HTTP GoalOperations, GoalResultWait1, GoalResultWait2, two waiters | FairWorker, FairNetwork, FairConsumer1, FairConsumer2, FairOwner |

The README contains direct commands; its same reuse/duplex restrictions and HTTP
two-handle change reproduce these variants. `GoalPublished` separates WebSocket
publication from result consumption; `GoalTerminal` covers individual mailbox
close/cancel requests independently of client shutdown. HTTP `GoalDelivery` permits
only the previously traced owner-abort exception, even before join. Owner join is
needed for `GoalOperations` to count unread/abandoned work as retired.

Each claim is finite `[]<>Goal`, not general temporal logic. Finite IDs never
recycle, so unresolved accepted work keeps publication/consumption goals false;
these checks exclude starvation of each accepted operation in the finite horizon.
Waiter goals exclude indefinite waits for nonexistent future work. Default waiter
coverage has one consumer of each kind; reuse/duplex wait entry is disabled and no
waiter-progress claim is made for them. Weak fairness of worker disjunctions does not
promise fairness for each branch; it suffices for the checked finite graphs.
`FairSendClock` combines eventual timeout with worker service, without any assumption
that a peer reads or replies. No proof establishes wall-clock bounds or production
scheduler behavior.

Adding a second HTTP waiter keeps the integrated model tractable; no new model or
larger state cap was needed. The largest new compiled check, covering operations and
both individual waiter goals with two handles, completed in **0.36 s** at **23,644 KiB**
peak RSS (about **23 MiB**), exit 0. This is one local release measurement, excluding
compilation, rather than a performance guarantee. Reproduce after setting both bounds:

```sh
/usr/bin/time -f 'elapsed=%e s peak_rss=%M KiB exit=%x' tlanif --max-states:400000 --live:GoalOperations,GoalResultWait1,GoalResultWait2 --fair:FairWorker,FairNetwork,FairConsumer1,FairConsumer2,FairOwner models/http_lifecycle.nif
```

Waiter state is now a map; the default one-caller graph retains exactly the old
state/edge counts. Each completion wakes one arbitrary sleeper, whereas final worker
exit wakes all. Two publications under the same lock wake both possible sleepers;
the model therefore explicitly restricts this abstraction to at most two callers.
Consumer helpers are expanded under a local caller binder, preserving one shared
implementation of consumption/recheck and separate scheduling assumptions.

The expanded model exposed two overly strong/weak interpretations of waiter progress.
`[]<>(all callers idle)` can fail while every caller repeatedly returns, because
their next calls overlap. The required checks select separate goals, establishing
each caller's progress without requiring simultaneous idleness. Conversely, weak
fairness of the combined consumer action permits one caller to starve while the
other repeatedly returns after worker failure. Individual fairness groups exclude
that scheduling behavior. These are modeling/assumption issues, not runtime defects.

Negative controls were also checked directly:

| Invocation change | Expected and observed result |
| --- | --- |
| HTTP GoalShutdown without fairness | Exit 3; stopping worker can stutter before exit |
| Frames GoalClose without FairClock, retaining FairCancel/FairClose/FairFinish | Exit 3; closing with a partial CLOSE can remain without expiry |
| WebSocket GoalWaiters with all five lifecycle fairness groups | Exit 3; running-client result wait can wake and re-sleep forever with no future results |
| HTTP GoalShutdown with FairWorker/FairNetwork and cap 10 | Exit 4; incomplete, no liveness conclusion |
| HTTP two waiters, individual goals with only aggregate FairConsumer (plus FairWorker/FairNetwork/FairOwner) | Exit 3; either caller can starve while the other keeps returning after worker failure |
| HTTP two waiters, GoalWaitersTogether with individual caller fairness | Exit 3; repeated calls can overlap forever despite each caller returning |

Failure witnesses were reference-validated by Tlanif. These failures are expected
assumption/contract diagnostics, not supported-API defects. Required goals exposed
no liveness violation. Direct CLI runs and manual result review suffice; the repository
contains no liveness scripts, graph interchange, output parser or saved traces.

Production sources reviewed at Relay commit `8b8a71bf9154b440a62c8831974f96cff608b20d`:

```text
src/relay/http.nim
7a24215fd04257587786e2948eb4677057ab16f1ae74bed044246a5277b437dc
src/relay/websocket.nim
566a2aeb21fe8245467558c9519f358b74cadff85ad5a1b744ac061c83b094d3
models/http_lifecycle.nif
bdbe3198faa6b93f81330133bc495d3dae0333870d7a3b2ac66b8544ac55cad9
models/websocket_lifecycle.nif
f5c8a12eaae1a7d435526a7f567a88d3cd3dc93848532a31c211a2774d1e32a7
models/websocket_frames_close.nif
b1476e1a11d3b1783b9d12f1e0c52cf69453e4656d3f5dbcc3aa3d717ba53884
```

All temporary variants were removed. The repository contains the three commented
specifications and their README/report, with no model scripts or generated caches.

The production-readiness review added [test_websocket_protocol.nim](../tests/test_websocket_protocol.nim)
to the default suite. Its real loopback peer covers empty text/binary messages, binary
bytes including NUL, a 48 KiB send across worker chunks, fragmented text with intervening
PING/PONG, receive timeout without closing, message-before-terminal ordering and retained
events after owner join. It also checks one bounded CLOSE without peer reply, full-budget
abort with and without prior cancel, exactly one retained operation completion/terminal,
and invalid UTF-8 after a valid message. Socket reads are bounded and each peer owns its
sockets. Unsupported linked libcurl versions explicitly skip this test.

On 2026-10-06 with WebSocket-enabled libcurl 8.18.0, the protocol test passed in default,
release, danger and AddressSanitizer configurations. The complete default suite,
`nim test tests/ci.nims`, passed all 14 standalone programs with threads and atomicArc.
ASan covered the new protocol test, not the whole suite; TSan was not run. No confirmed
runtime defect emerged. These tests support the checked transport paths; the native
models separately establish the bounded progress claims above. Neither establishes
complete memory safety, unbounded progress or all peer/TLS interoperability.

The subsequent concurrency additions passed in default, release, danger and ASan
builds, with threads and atomicArc. Only the two changed test programs were rerun;
the full 14-program suite result above predates these additions.

`test_websocket_protocol.nim` now creates two independent clients on separate owner
threads released together. Both connect and exchange distinct messages with separate
loopback peers. One owner cancels/aborts and releases its libcurl reference while the
other connection remains open; the survivor then sends and receives again and closes
gracefully. Each owner shuts down its own client, socket reads and phase waits are
bounded, and no duplicate completion/terminal is retained.

[test_lifecycle_contracts.nim](../tests/test_lifecycle_contracts.nim) now starts two
raw waitForResult callers on one HTTP client, then submits two timed-out loopback
transfers with distinct requestIds. Both callers return exactly once with distinct
completions; outstanding and ready results are empty. Owner shutdown happens only
after both caller threads join. This tests concurrent raw retrieval, preserving the
exclusive-use requirement for blocking convenience helpers.

No implementation defect emerged from these additions. The concurrency coverage is
two independent WebSocket clients and at most two HTTP result callers; arbitrary
numbers of clients/callers and unbounded scheduling fairness remain outside the claim.
