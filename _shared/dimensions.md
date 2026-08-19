# The dimensions — the completeness checklist

Every dimension below MUST be walked by `prod-bootstrap` in Phase 2 (asked, if
it needs a human semantic answer) and Phase 4 (a gap-report row, always). The
ONLY legal way to omit one is an explicit `declined:` entry with a rationale in
the spec's `out_of_scope`. **A bootstrap whose gap report is missing a row, or
whose Q&A skipped a human-only question, is incomplete — the human must never
have to ask "where is X?".** `prod-review` uses the same list as its gap-
discovery frame.

For each dimension: what to inventory (facts), what to ASK (human-only
semantics), and what the gap-report row must state.

## 1. Correctness — structural
Inventory: line/branch coverage today, the repo's own floor if any, whether
changed-line coverage is measured at all, tests/production LOC ratio (record
it — **informational, never a gate**), test count and distribution.
Ask: the changed-line coverage SIGNAL threshold for this tier; whether the
repo's existing global floor stays as-is, rises, or becomes a ratchet
(high-water minus epsilon).
Row: coverage today vs the standard's signal, and which mechanism measures it.

## 2. Correctness — fault sensitivity
Inventory: any mutation tooling, any coverage-of-assertions notion.
Ask: nothing (mutation is advisory by policy — never a gate).
Row: mutation baseline exists or not; it is a TREND.

## 3. Behavioral — invariants and properties
Inventory: declared invariants (in code, docs, metric manifests), property
tests, metamorphic relations, fuzz targets and what they cover.
Ask: "what must never happen?" → candidate invariants; which decode/parse
boundaries need fuzzing.
Row: ratified invariants count, property/fuzz coverage of the core.

## 4. Scenarios — the failure-mode matrix
Inventory: per declared capability CLASS, walk its canonical failure checklist
and mark each entry tested / untested / not-applicable (unit, integration,
e2e, chaos). This produces the matrix AND the ScenarioCoverage denominator —
which must come from the class checklists, never from the author's memory.
Ask: which UNLISTED failure modes this system has learned the hard way
(incidents, near-misses); which checklist entries are genuinely N/A here.
Row: matrix completeness per capability, and the tested/identified count.

**`poison_message` is satisfied by PROGRESS, not by complaint.** A consumer
that counts an undecodable message, logs it loudly, and then cannot advance
past it has not handled the poison — it has narrated its own deadlock. Found
in a scaffolded service whose comment said the stall was "loud, not silent",
which was true and beside the point: silent-vs-loud is not the axis, and the
consumer never recovered. The honest question for this scenario is *what does
the consumer do NEXT*, and there are only three real answers — skip the
message and advance past it, park it somewhere durable and advance, or stop
deliberately and page a human. Counting it is not one of them. Whichever is
chosen, the test must show the consumer processing the message AFTER the
poison one.

## 5. Integration and contracts
Inventory: what real dependencies are exercised in tests vs faked (does ANY
test touch a real DB/broker/venue? containerized?); contract/compat checks
(schema-breaking detection, generated-client drift); consumers of this
service's surface.
Ask: which boundaries deserve a real-dependency integration lane vs staying
hermetic (cost vs fidelity); the compatibility policy (N-1 coexistence?
expand/contract on schemas? who breaks if the served contract changes?).
Row: integration fidelity today, compatibility gates present or absent.

## 6. Performance and capacity
Inventory: benchmarks that exist, versioned workloads, baseline history,
profiling artifacts, declared SLOs, known saturation point.
Ask: the hot path's latency budget and expected peak; whether an absolute SLO
is asserted anywhere or only relative regression; capacity safety margin.
Row: benchmark baseline exists or not (SIGNAL, statistical, never absolute in
shared CI), scalability curve known or unknown, capacity margin measured or
unmeasured.

## 7. Resilience and recovery
Inventory: fault-injection harness, crash/restart tests, outbox/journal on
effects, recovery functions and their tests, reconciliation jobs, backup and
its restore test, plus the two the framework wants FIRST-CLASS and that are
easy to lose: **backpressure** (what happens when input rate > processing
rate — queue/drop/reject/slow-producer must be an explicit, tested decision)
and **resource isolation** (one tenant/venue/partition going pathological
must not starve the others: bulkheads, per-partition pools, quotas — with
the canonical test "stall partition X completely; does Y still serve?").
**An outbox whose journal is not atomic with the state change is not an
outbox.** The pattern's entire value is that the intent and the state commit
either both survive a crash or neither does; the classic implementation gets
that by writing the outbox row in the SAME transaction as the state change.
Copy the shape without the atomicity and you have a queue with extra steps,
plus a silent failure mode: this framework's own template shipped
`journal.Append(event)` -> commit state -> unlock -> `outbox.Journal(effects)`,
three separate steps across two files with two independent fsyncs. A crash in
the window leaves the event durable and replayable while the effect is lost
forever -- and replay cannot recover it, because the fold discards effects
(`state, _ = Apply(...)`). The blast radius is the worst available: an effect
folded durably and correctly that never reaches the outside world, with no
signal anywhere saying so.
Two honest resolutions: a real transaction where a database exists; or, in an
event-sourced design without one, rebuild the outbox at boot as a PROJECTION of
the event log plus a delivery watermark -- legitimate precisely because `Apply`
is deterministic, so the effects of any event are re-derivable from the event
itself.

Ask: what the system must guarantee across a restart (what may be retried,
what must NOT, what is reconciled); whether durable state exists at all (if
none, record reconciliation as N/A with that reason); and whether the effect
journal is ATOMIC with the state change or merely adjacent to it.
Row: recovery semantics tested or assumed; reconciliation present, N/A, or
missing; restore test cadence.

## 8. Observability
Inventory: metrics/traces/logs inventory, correlation ids, cardinality
discipline, invariant counters, whether an observability contract is checked
in CI, and **operational determinism**: are code, config, schema and flag
versions surfaced in the signals? (`Output = F(code, config, state, inputs)`
— without all four versioned, a replay cannot reproduce production, so this
is a precondition of dimension 7, not a nicety.)
Ask: which state transitions MUST be observable for 3am debugging.
Row: contract checked mechanically or documentation-only; build/config
identity surfaced or absent.

**Wiring cannot be grepped.** A tracer, a metric or a hook that is imported,
constructed, or merely defined satisfies every text search you can write and
still never runs: a discarded variable, a helper nobody calls, and a contract
test's own call sites all match. Three successive tightenings of this check were
each fooled by the next shape. Treat a grep as an existence signal and nothing
more — the only evidence that instrumentation REACHES production is a test that
exercises the entrypoint's own construction path, or the signal appearing in a
real environment. Say which one you have.

## 9. Security
Inventory: authz/authn surface, policy-as-invariant candidates, secret
scanning (on which triggers), dependency vulnerability scanning, SBOM,
artifact signing/provenance, secretless presubmit, network policy.
Ask: which authorization rules are invariants ("A can never reach B"); what
must never be reachable from outside.
Row: each supply-chain gate present/absent; policy invariants declared or not.

**Every WRITE surface needs authentication or a ratified decline naming who
can reach it.** Read-only health and metrics endpoints are one thing; an
endpoint that accepts work is another, and "it only listens on loopback"
stops being true the moment a container publishes the port. Found in a
scaffolded service that accepted orders on behalf of ANY account with no
credential of any kind — while its own README criticised its upstream for
exactly that. The decline is a legitimate answer for a local-only tool; an
unexamined open port is not, and the difference is whether anyone wrote down
which one it is.

Same shape for the DEPLOYMENT artifacts: a container with no memory or CPU
limit lets one runaway process take the host, which is a security property as
much as an operational one. If the repo ships a compose file or manifests,
they are part of this inventory.

## 10. Deployability and operability
Inventory: promotion path, canary/progressive delivery and its analysis,
rollback mechanism and its rehearsal, migration discipline, runbooks, alerts
and SLOs, ownership, liability registries.
Ask: the promotion gate for this tier (automatic? human ack?); what an
operator must be able to do at 3am without reading the code.
Row: canary analysis automated or manual, rollback rehearsed or assumed,
runbooks tested or stale.

**Gate integrity — the gates must be RUNNABLE, and only something outside CI
can say so.** Ask of every gate: if this could not run at all, what would go
red? On GitHub the honest answer is often "nothing": an invalid workflow file
yields a zero-second run with no jobs and no check runs, so the PR reports "no
checks reported", the required contexts stay unfulfilled forever, and no red
signal exists to investigate. A gate that cannot run is indistinguishable from
a gate that passes, which makes this the same failure as a vacuous test — the
oracle has to sit outside the thing it judges. Validate the CI definitions in
the local cheap gate and in the probe, never only in CI. Row: gates proven
runnable from outside, or assumed runnable because nothing was red.

## 11. Reproducibility
Inventory: are code, config, data/schema and environment each versioned and
recoverable for a past run? Is there an evidence record per commit (which
policy version, which gates, which seeds, which waivers applied)? Can the
question "under what standard was this commit written?" be answered without
archaeology?
Ask: nothing — this is derived from what exists.
Row: the four versions and the per-commit evidence record, present or absent.
(The framework's own v0 is a flat JSON per commit; anything less means the
standard a commit was held to is unknowable later.)

## 12. Scalability — vertical and horizontal

**This dimension is REQUIRED BY DEFAULT.** Unless a repo records a ratified
decline with a reason, assume the system must scale both vertically (more work
on one instance) and horizontally (more instances). "It is fine at current
volume" is not an answer — it is the assumption this dimension exists to make
explicit, because it is always true right up until it is catastrophically not.

Inventory: **boot time as a function of history** (does recovery replay from
genesis, or from a snapshot?); the **snapshot/compaction story** for every
append-only store; **what grows without bound** — every log, queue, buffer and
in-memory index needs an answer, and "nothing prunes it" is an answer that
must be written down; **backpressure at every boundary in BOTH directions**
(dimension 7 and the tier policy's `isolation_and_backpressure` cover ingress
rate only, which leaves the common hole: egress accumulating without limit
while a downstream is absent); the **partition key**, or the reason there is
none; and **which side of the durability/throughput trade** the hot path sits
on.

Ask: what is the partition key for this workload — and if the answer is "there
isn't one", is the state genuinely single-writer or merely single-writer *so
far*? What is the acceptable loss window on a crash (that answer chooses
between fsync-per-event and group commit, and both are correct answers to
different questions)? What is the largest history this system should still boot
from, and how long may that take?

Row: bounded boot (snapshot mechanism present, or replay-from-genesis with the
history bound stated); bounded storage (every append-only store has a retention
or compaction policy, or a declared decline); egress backpressure (bounded, or
declined); partition key declared, or single-writer ratified as a decline with
its reason; durability trade stated.

**Four defects that motivated making this a gate**, all shipped by a service
built from this framework's own template, each defensible at 2 messages/second
and none surviving real volume:

- **Boot was O(N) from genesis.** The event log replayed from the first event
  on every start and never compacted. 172k events/day boots in seconds; a
  billion takes hours. Nobody had written down which of those the system was
  expected to survive.
- **Backpressure existed on one side only.** Consumption was pull-based, so it
  self-paced — correct, and partly by accident. The outbox had no bound at all:
  a downstream outage accumulated entries forever, and the only thing that
  would eventually stop it was the disk.
- **Horizontal scale was declared away in prose.** The spec said "no
  concurrent-writer conflict resolution exists or is needed *at this scale*".
  Honest, and the qualifier was doing all the work: nothing recorded what would
  change if the scale did, and no one had to justify it.
- **fsync per event on the hot path, under the mutex**, bought a zero-loss
  window at ~45ms p99. A real venue does group commit and accepts a bounded
  loss window instead. Either is defensible; shipping without saying which
  question you were answering is not.

**Partitionable is not the same as partitioned.** A system does not need to run
sharded today, but its state must be *decomposable* along a key, and that is
cheap to preserve and expensive to retrofit. In the service above the order
books were already per-symbol and fully independent — the obstacle to
partitioning was not the domain, it was a single shared monotonic cursor
threaded through everything. That coupling cost nothing to avoid at design time
and would cost a rewrite to remove. Notice it early; that is most of the value
of asking.

## 13. Bounded auto-recovery

**This dimension is REQUIRED BY DEFAULT.** Dimension 8 asks whether a failure
is VISIBLE. This one asks whether the system comes BACK, and within what bound.
They are different questions, and a framework that only asks the first produces
services that detect beautifully and stay down.

The defence that gets written for these is "loud, not silent" — and it is true
and beside the point. **Silent-vs-loud is not the axis; recoverable-vs-wedged
is.** §4's `poison_message` note is one instance of this rule; this dimension
is the general form, applied to every failure mode the system detects.

Inventory: for each failure mode in the §4 matrix, does the system return on
its own or does it require a human? The bound on that return. And — the part
that is easiest to miss — whether the recovery mechanism is actually WIRED,
not merely implemented and tested.

Ask: what is the longest a detected failure may persist before someone is
paged? Which modes genuinely need a human, and why can they not be automated?

Row: self-recovery proven by a test that INDUCES a failure and shows the
system returning unaided; the recovery bound stated as a duration; every mode
that needs intervention named as a ratified decline with its reason.

**Three defects that motivated it**, all found in services built from this
framework:

- **An undecodable message wedged a consumer permanently.** It was counted,
  logged and panelled. The cursor could not advance past it, so every later
  message was a gap, forever. Detection was perfect; recovery did not exist.
- **An upstream restarted its own history**, leaving the consumer polling a
  position that no longer existed — receiving nothing, reporting nothing,
  indefinitely.
- **An outbox whose recovery half was never invoked.** `Reconcile` existed,
  had passing tests, and was called from nowhere in production code. The tests
  proved the mechanism; only the composition root proves it RUNS, and a test
  suite cannot tell the difference. This is the same defect class as a tracer
  that is constructed and thrown away, and it is why this dimension asks about
  wiring rather than about existence.

**"There is a retry" is not an answer; "it returns within N seconds, and here
is the test that induced the failure and timed it" is.** A failure you can
provoke is a recovery you can time — which is what makes a scenario driver
(§4) the natural instrument for this dimension rather than a separate effort.

## 14. The published contract

**Required wherever anything is published to a consumer this repo does not
own.** A published event is an API, not an implementation detail.

The asymmetry this exists for, observed in a service built from this
framework's own template: it versioned the formats **only it read** with real
rigour — `schema_version` stamped per record, write-one-read-many, golden
fixtures per version, loud refusal on an unknown version — while the payload it
**published** to other people's consumers carried fourteen JSON fields and no
version at all.

That is exactly backwards from where the cost falls. You can migrate your own
log whenever you like, because you are the only reader. **You cannot migrate
someone else's consumer.** The rigour was pointed at the cheap problem.

Inventory: every payload that leaves the process for a reader this repo does
not control — broker subjects, webhooks, API responses, files written for
another system. Whether each carries a version a consumer can branch on.
Whether a test pins the emitted shape. Who the known consumers are.

Ask: who reads this, and what happens to them when a field is renamed? Is the
compatibility promise expand/contract, or a versioned envelope with parallel
shapes?

Row: every published payload versioned; the emitted shape pinned by a test
that fails when it changes; the compatibility policy declared; consumers named
or their absence recorded.

**This is deliberately NOT folded into §5's `compatibility`.** That entry is
satisfied by any wire or golden test, including one over a format nobody
outside this repo parses — and that is the format you can always fix. The
audience is what makes this dimension expensive, so the audience is what it
keys on. A repo can be fully compliant with §5 and still break every downstream
consumer on its next deploy.

## 15. Data lifecycle

**Required wherever subject data exists.** This framework pushes services
toward event sourcing (§12, and the derivation in prod-new), so it creates this
problem and therefore owes an answer to it.

**"Delete this subject's data" is genuinely hard when the source of truth is an
immutable append-only log** — and harder once a snapshot has folded that data
in, because deleting the log record leaves the snapshot still holding it.
Retention is the same dimension: how long history is deliberately kept, which
is a policy commitment with a different owner from §12's `bounded_storage`
(that one asks only whether *something* prunes the store).

Inventory: what subject data exists (accounts, tenants, people); the retention
policy and what enforces it; the deletion mechanism; how deletion interacts
with snapshots, with the replay corpus, and with downstream consumers who have
already received the data.

Ask: does this system hold data about an identifiable subject who can demand
its removal? How long must history be kept, and by whose requirement?

Row: retention policy declared; deletion mechanism declared from a closed set;
where a real mechanism is claimed, a test proving a deletion request removes
the data from the log AND from any snapshot that already folded it in.

**Both real designs must be chosen at design time.** *Crypto-shredding*
encrypts per subject and deletes the key, so the ciphertext becomes noise and
the log stays immutable. *Tombstone-plus-rebuild* appends a deletion marker and
rewrites history behind it. Neither retrofits cheaply, and the choice
constrains the storage layer — which is why it belongs beside the event-log
decision rather than after it. A service that reaches this question late
discovers that its immutability guarantee and its deletion obligation are the
same guarantee pointing in opposite directions.

**Downstream is the half people forget.** Deleting your own copy does nothing
about the consumer who received the event last Tuesday. If §14's consumers are
named, this is answerable; if they are not, it is not — which is one reason
these two dimensions are worth having together.

## Cross-dimension metrics worth computing because they are nearly free
- **Oracle gap** per package: structural coverage MINUS mutation score. A big
  gap localizes weak assertions better than either number alone; both inputs
  already exist (coverage as SIGNAL, mutation as TREND). Report per package in
  the trend lane, never as a gate.
