The HTTP model exposes an accepted request that can lose its completion during abort.
WebSocket's checked properties have no violation within the stated finite bounds.
Direct Tlanif results are recorded below. Temporal liveness is discussed from the
source; Tlanif's safety CLI does not prove eventual progress.
The [README](README.md) defines bounds, atomicity and fairness.

These observations are **TRACED** from source and model interleavings. There is no
deterministic runtime reproduction here, and the models do not establish memory safety.
Reviewed fingerprints are recorded below; changed source requires retracing the
models and findings. No production code is modified.

HTTP's completion loss follows this legal schedule in
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

Both Tlanif evaluators produce an eight-state shortest trace. Owner join subsequently
resets queue and outstanding, abandoning that request. This violates the README's
“Every request yields exactly one RequestResult” behavior while respecting submission
and owner-shutdown threading constraints. Worker shutdown completes; the failing
progress property is completion delivery, not worker deadlock. No result waiter exists
in this counterexample.

The ordinary workerMain abort branch flushes; the waitForWorkOrClose abort branch does
not. An idle worker can also be signalled by submission and aborted before rechecking
its wait predicate. The NIF keeps the strong completion invariant as its default check.
Separate CoverageInv runs verify accounting without claiming delivery. The trace
already demonstrates the delivery-progress failure: after owner cleanup, stage 9
cannot return to a state with a completion. Routing late abort through flush is a
possible repair, but requires production changes and a regression test.

HTTP [shutdown](../src/relay/http.nim:288) discards unread results and destroys
synchronization after join. This is documented: drain/query before shutdown; afterwards
only repeated close/abort are supported. The model allows discard of already-published
results, distinguishing it from the abort race's unpublished request. WebSocket retains
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
modeled caller constraint. WebSocket explicitly documents one result consumer. HTTP's
multiple-blocking-consumer semantics are unclear in its docs; the single-waiter model
cannot settle support or starvation under repeated signal calls.

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
HTTP stopped-pending is reachable because of the abort defect. An absent probe alone
is not evidence of a dead source branch.

Cached derived state is intentional: outstanding counts accepted work minus consumed
results (with HTTP's explicit owner reset); WebSocket queuedBytes sums message lengths.
Conservation protects both. Worker-stopped versus owner-closed, retention versus phase,
frame-started versus offset, and incoming-active versus bytes are necessary distinctions.
HTTP handle ownership differs from table registration. Stage/publication/history and
deadline/delivery counters are ghost instrumentation. Disabling events/waiters in a
reduced scenario leaves their maps equal to zero; this does not justify deleting
implementation fields.

Limits include finite identities, abstract failures, no curl/OS proof, ARC safety,
constructor rollback, byte parsing, TLS, retry correctness, exact error kinds, multiple
HTTP waiters or wall-clock guarantees. Progress relies on stated fairness: an unscheduled
worker, nonadvancing transfer deadline or unwilling consumer can stall independently.

Direct validation on 2026-10-06 used `tlanif` from PATH. Counts below agree between
sequential-reference and `--jobs:4` compiled-parallel exploration, with cap 400,000:

| Specification / variation | Safety result | States |
| --- | --- | ---: |
| WebSocket lifecycle, default | Pass, including stopped-waiter wakeup invariant | 91,346 |
| WebSocket frames/close | Pass | 58,180 |
| WebSocket reuse, restrictions in README | Pass | 213,205 |
| WebSocket duplex, restrictions in README | Pass | 166,938 |
| HTTP default completion invariant | Fail: accepted request remains queued at worker exit | 8-state shortest counterexample |
| HTTP CoverageInv, one handle | Pass for accounting/resource/wakeup properties only | 5,533 |
| HTTP CoverageInv, two handles | Pass for accounting/resource/wakeup properties only | 7,385 |

Direct reachability checks used `(check (not WitnessName.0.))`. Their expected
counterexamples show reachability, not implementation failures:

| Probe | Bounds | Sequential / parallel result |
| --- | --- | --- |
| WitnessBudgetFull | Two fresh WebSocket IDs, one slot | Reachable, 14-state trace; first terminal consumed while its result remains, second connect admitted |
| WitnessIsolation | Reduced duplex variation | Reachable, 15-state trace; canceled connection finished, another open with send completion |
| WitnessTransferOutOfOrder | HTTP one handle | Absent, all 5,533 states explored |
| WitnessTransferOutOfOrder | HTTP two handles | Reachable, 13-state trace; second request finalizing while first remains in flight |

An unrestricted two-connection WebSocket witness exploration exceeded the 400,000-state
cap and is **incomplete**. It supplies no verification claim. The documented reduced
variations completed. No temporal liveness claim is derived from these safety runs.
Final broadcast is checked as a safety condition: stopped state must not retain an
asleep waiter. Eventual execution of awakened callers still needs scheduler fairness.

Production sources reviewed at Relay commit `8b8a71bf9154b440a62c8831974f96cff608b20d`:

```text
src/relay/http.nim
7a24215fd04257587786e2948eb4677057ab16f1ae74bed044246a5277b437dc
src/relay/websocket.nim
566a2aeb21fe8245467558c9519f358b74cadff85ad5a1b744ac061c83b094d3
models/http_lifecycle.nif
3e6a88dd88a53927f00f9054ae60f8267760d242966c0d6ed3c8e9e4100828ba
models/websocket_lifecycle.nif
9dfb0e4dce0f94ab23216f3c9a8810c803021cd999973ac14c0d873235d9214d
models/websocket_frames_close.nif
b1476e1a11d3b1783b9d12f1e0c52cf69453e4656d3f5dbcc3aa3d717ba53884
```

All temporary variants were removed. The repository contains the three commented
specifications and their README/report, with no model scripts or generated caches.
