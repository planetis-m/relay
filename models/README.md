# Relay models

Three commented Tlanif specifications cover the current HTTP and WebSocket workers.
Source mappings, state encodings and action boundaries are documented in the `.nif`
files. Worker snapshots and private setup/finalization remain separate from locked
queue operations so their races are explored.

| Model | Coverage | Default bounds |
| --- | --- | --- |
| [websocket_lifecycle.nif](websocket_lifecycle.nif) | Client/worker lifecycle, commands/results, budgets, mailboxes, cancellation, shutdown and waiters | One connection, two operations, one retained slot, budget two |
| [websocket_frames_close.nif](websocket_frames_close.nif) | Partial frames, fragmented messages, queue limits, event ordering and close handshake | Two sends, three receive publications, capacities two |
| [http_lifecycle.nif](http_lifecycle.nif) | Admission, handle ownership, queue/in-flight/results, cancellation, shutdown and result waiters | Two requests, one handle, one waiter |

The WebSocket split avoids multiplying frame state by lifecycle state. HTTP remains
one integrated model. Operation identities do not recycle; HTTP model identities
are distinct from caller-supplied `requestId` values.

## Run

Use `tlanif` from PATH, with native liveness support, from the repository root.
Safety checks:

```sh
tlanif --max-states:400000 models/websocket_lifecycle.nif
tlanif --max-states:400000 models/websocket_frames_close.nif
tlanif --max-states:400000 models/http_lifecycle.nif
```

Repeat each command with `--jobs:4` for compiled parallel evaluation. Passing state
counts, or shortest failure depths, must agree with the reference evaluator.

Liveness checks select progress goals and their weak-fairness assumptions explicitly:

```sh
tlanif --max-states:400000 --live:GoalShutdown,GoalTerminal,GoalPublished --fair:FairWorker,FairDue models/websocket_lifecycle.nif
tlanif --max-states:400000 --live:GoalCompletions,GoalResultWait --fair:FairWorker,FairDue,FairResult models/websocket_lifecycle.nif
tlanif --max-states:400000 --live:GoalEventWait --fair:FairWorker,FairDue,FairEvent,FairWaitClock models/websocket_lifecycle.nif
tlanif --max-states:400000 --live:GoalClose --fair:FairCancel,FairClose,FairClock,FairFinish models/websocket_frames_close.nif
tlanif --max-states:400000 --live:GoalSends --fair:FairSendClock models/websocket_frames_close.nif
tlanif --max-states:400000 --live:GoalShutdown,GoalDelivery --fair:FairWorker,FairNetwork models/http_lifecycle.nif
tlanif --max-states:400000 --live:GoalOperations --fair:FairWorker,FairNetwork,FairConsumer,FairOwner models/http_lifecycle.nif
tlanif --max-states:400000 --live:GoalResultWait --fair:FairWorker,FairNetwork,FairConsumer models/http_lifecycle.nif
```

All default checks pass. Append `--live-eval:reference` for differential liveness
verification. Liveness is single-worker and does not accept `--jobs` or `--sym`.
A goal means `[]<>Goal`; an action disjunction is one fairness group, not separate
fairness for every branch. Shutdown and publication do not assume consumers run.
Consumption assumes willing callers, and HTTP owner cleanup assumes eventual join.

A state-limit hit is incomplete, never a pass. Safety exit 2 can mean either a
violation or cap exhaustion; read the diagnostic. Liveness uses exit 3 for a fair
counterexample, 4 for incomplete exploration and 5 for no admissible fair behavior.

## Checked variations

Edit the constants and listed references in `Next`, then repeat the checks and
restore the defaults. Keep action definitions intact.

| Variation | Constants | Actions omitted from Next |
| --- | --- | --- |
| WebSocket reuse | Ids=1..2, Slots=1, SeedOpen=false | BeginEventWait, BeginDispose, BeginResultWait |
| WebSocket duplex | Ids=1..2, Slots=2, SeedOpen=true | Same three waits, plus PublishMessage, RequestClose, PollEvent |
| HTTP concurrent transfers | Handles=2 | None |
| HTTP concurrent result callers | Waiters=1..2, Handles=1 or 2 | None |

Duplex begins with two open connections and permits two new sends across either.
Reuse/duplex disable wait entry, so they establish no waiter-progress claim.

For two HTTP callers, replace the single-consumer progress checks with:

```sh
tlanif --max-states:400000 --live:GoalOperations,GoalResultWait1,GoalResultWait2 --fair:FairWorker,FairNetwork,FairConsumer1,FairConsumer2,FairOwner models/http_lifecycle.nif
```

Each caller needs its own fairness group and goal. `GoalWaitersTogether` is a
diagnostic stronger condition: callers can return individually without ever being
idle simultaneously. An empty running-client result wait may legitimately continue
until future work or worker stop, including when another consumer took its result.

To probe reachability, replace the existing check with
`(check (and Inv.0. (not WitnessName.0.)))`. A counterexample proves the witness
reachable; an exhaustive pass proves it absent within the bounds. Tlanif uses only
the last check form. Diagnostic failures are explained in [REPORT.md](REPORT.md).

## Scope

Shutdown belongs to the creating thread after other callers finish. Blocking
convenience helpers require exclusive access. WebSocket sends follow connect success;
its model has one result consumer and one event/disposal consumer per connection.
HTTP retrieval ends at owner shutdown; WebSocket retains results/events afterwards.

The models abstract payloads, curl/OS behavior and error categories. They do not prove
unbounded progress, wall-clock bounds, memory safety, TLS or parsing correctness.
The [report](REPORT.md) records the completed checks and complementary runtime tests.
Recheck when the implementation or model changes.
