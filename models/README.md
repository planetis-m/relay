Three commented Tlanif/TLA-style specifications cover Relay's current workers:

| File | Coverage |
| --- | --- |
| [websocket_lifecycle.nif](websocket_lifecycle.nif) | Client/worker lifecycle, commands/results, budgets, connection ownership, mailboxes, cancellation, shutdown and waiters |
| [websocket_frames_close.nif](websocket_frames_close.nif) | Partial frames, fragmented messages, queue bounds, event ordering and close handshake |
| [http_lifecycle.nif](http_lifecycle.nif) | Batch admission, easy-handle pool, queue/in-flight/private ownership, results, queue clearing, shutdown and waiters |

The WebSocket split keeps frame state from multiplying lifecycle/mailbox state.
HTTP fits in one integrated model. Source mappings, state encodings, atomicity and
assumptions are documented directly in each `.nif` file.

Run Tlanif from PATH directly from the repository root. Native liveness requires
Tlanif commit `741bff8` or later.

```sh
tlanif --max-states:400000 models/websocket_lifecycle.nif
tlanif --jobs:4 --max-states:400000 models/websocket_lifecycle.nif
tlanif --max-states:400000 models/websocket_frames_close.nif
tlanif --jobs:4 --max-states:400000 models/websocket_frames_close.nif
tlanif --max-states:400000 models/http_lifecycle.nif
tlanif --jobs:4 --max-states:400000 models/http_lifecycle.nif
```

All default checks should pass. HTTP explicitly permits owner abort to discard
unfinished work, matching its shutdown contract. Exit 0 means safety passed;
exit 2 can mean an invariant failure or state-limit hit, so read the diagnostic.
A limit hit is not validation. Sequential and compiled-parallel counts, or shortest
failure depths, must agree.

Set HTTP `Handles` from one to two to exercise concurrent transfers and reverse
transfer completion. Its diagnostic `StrictCompletionInv` requires publication even
during owner abort; checking it produces an eight-state counterexample to that stronger
policy. This is allowed discard, not a supported-API defect. Restore the original
check/bound after exploration. No wrapper, result parser,
Python dependency or generated report machinery is necessary.

Default bounds: WebSocket lifecycle has one fresh connection, two operations, one
retained slot and budget two. Frames/close starts with two accepted sends and allows
three receive publications; message/byte/event/control capacities are two, versus
eight controls in the implementation. HTTP has two logical request objects and one
easy handle. Identities do not recycle. HTTP object IDs are independent of caller
requestId values, which can repeat.

The following variations were also checked; edit constants and remove the listed
action references from Next, then restore the default file after exploration:

| Variation | Constants | Actions omitted from Next |
| --- | --- | --- |
| WebSocket reuse | Ids=1..2, Slots=1, SeedOpen=false | BeginEventWait, BeginDispose, BeginResultWait |
| WebSocket duplex | Ids=1..2, Slots=2, SeedOpen=true | Same three waits, plus PublishMessage, RequestClose, PollEvent |

The duplex horizon starts after successful connects and permits two new sends in
total, distributed across either connection. The default one-connection horizon
cannot prove multi-connection behavior. Unrestricted larger variations can hit the cap.
Witness predicates expose both intended reachable states and invariant exclusions;
absence can also follow the finite bounds. To check a particular witness with Tlanif,
use `(check (not WitnessName.0.))`: a counterexample proves it reachable; an exhaustive
pass proves it absent in that bounded model. Replace the existing check; Tlanif uses
only the last check form, so multiple checks must be combined into one conjunction.

These models follow `~/Projects/tlanif/README.md` and `AGENTS.md`: comments attach to
tokens, module symbols have trailing dots, bound locals do not, Init primes every
variable, and stutter tuples list every variable. Definitions are acyclic and omitted
primes stutter. No unsupported temporal or `case` syntax is used.

The safety commands above check final wakeup publication and stopped cleanup.
Run native bounded liveness with explicit goals and fairness groups:

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

These commands pass. Append `--live-eval:reference` to repeat with the interpreter;
both evaluators agree. Liveness is single-worker; do not add `--jobs` or `--sym`.
Exit 3 reports a fair counterexample; exit 4 means incomplete, and exit 5 means
no admissible fair behavior. Only an exhaustive exit 0 establishes bounded progress.

Each selected goal means `[]<>Goal` under weak fairness of the selected action
groups. A disjunction or existential action is one group, not fairness for each
branch or connection. Finite operation identities never recycle: publication and
consumption goals therefore exclude permanent starvation of any accepted operation
within the horizon. Shutdown/publication checks do not require consumers to run.
HTTP delivery permits owner-abort discard; full operation retirement additionally
assumes owner join. Frame send fairness abstracts deadline expiry and worker service
together, without requiring peer cooperation or successful delivery.

Waiter progress covers one result consumer and, in the default WebSocket model,
one event/disposal consumer. An empty result wait on a running client can legitimately
remain blocked indefinitely; `GoalResultWait` excludes that case. `GoalWaiters` is
an intentionally failing diagnostic. Reuse/duplex disable wait entry, so their
liveness checks cover shutdown, terminal state, publication and consumption only.
These proofs do not establish progress for unbounded work or multiple competing waiters.

Caller constraints include creating-thread shutdown after other callers finish,
exclusive access for blocking helpers, WebSocket sends after connect success and one
event/disposal consumer per connection. One result consumer is modeled. HTTP public
calls after owner close are excluded; WebSocket retained results/events remain usable.
The models abstract payloads, error categories, curl/OS internals, ARC memory safety,
constructor rollback, parsing, TLS, retry behavior, unbounded work and real-time bounds.

[REPORT.md](REPORT.md) records the reviewed source fingerprints and direct results.
Recheck after changing source or models; a result applies only to its recorded inputs.
