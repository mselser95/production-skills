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

---

## The standing rule above every dimension: VERIFY END TO END WHEN YOU CAN

**If a runnable environment exists, the claim "it works" means you RAN it and
looked. Nothing else counts.**

Every dimension below can be satisfied piece by piece and still leave the
system not working, because the dimensions verify MECHANISMS and a user cares
about PROPERTIES. A property lives in the gaps between mechanisms, and the gaps
are exactly what no unit test covers.

Measured, on a repo that had just passed 60 probe rows with zero failures:

    115 log lines in the log store.  ZERO carrying a trace id.

Every component was correct and had been verified individually — the OTLP log
bridge, the W3C propagator, the exporter, the backend's ingestion, the
dashboard links. Nothing was broken. There was simply nothing to correlate:
every log call lived in an adapter and every span lived in the orchestration
layer, so no line was ever emitted INSIDE a span. No test in that repo could
have found it, because each half was doing its job. One `docker compose up` and
one query did.

So, before claiming a system-level property holds:

- **Run the real thing.** `docker compose up`, the staging stack, whatever
  exists. A green suite tells you the parts behave; only the running system
  tells you they add up.
- **Query the destination, not the emitter.** "The exporter was called" is a
  mechanism. "The record is in the store, and I read it back" is the property.
  Check the far end.
- **Follow one real transaction across every boundary it crosses**, and name
  the boundaries it does NOT cross. That walk is what surfaces a segment
  everybody assumed somebody else covered.
- **State which half you have.** "Unit-proven, not observed in a deployment" is
  a complete and honest answer. "It works" without a run is not, and it is the
  claim that gets found out by the person who trusted it.
- If no environment can be stood up, say so explicitly and say what that leaves
  unverified — an absent E2E check is a gap in the report, never a silence.

The failure mode this exists to stop is not sloppiness. It is the reasonable
inference that N correct mechanisms compose into a working system. They
frequently do not, and the difference is invisible from the inside.

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
(schema-breaking detection — an event-driven surface means a broker's schema
registry or an equivalent compatibility check, not only a synchronous API
contract — generated-client drift); consumers of this service's surface.
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

**The PRODUCTION profile belongs to dimension 8, not here.** This dimension
owns the profile you take of a benchmark, on your hardware, to explain a
regression you can already reproduce. That is a performance instrument and it
is the easy half. Whether a profile of the process that was actually slow —
last Tuesday, in production, on the build that was deployed then — exists at
all is an observability question, because it is about what signal was being
recorded before anybody knew to look. See §8.

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

**There are FOUR signals, not three.** Metrics, traces, logs — and profiles.
The fourth is the one this framework left out for a year, and the two entries
below are the correction: profiling is owed by every service including the
headless ones, and tracing is owed only by some and the condition is
derivable.

Inventory: metrics/traces/logs inventory, correlation ids, cardinality
discipline, invariant counters, whether an observability contract is checked
in CI, **continuous profiling** (see below — collected always, or only when
somebody goes looking), whether distributed tracing is WARRANTED here at all
(derived, not asked — `mechanism-derivation.md` §8) and if so whether it is
wired, and **operational determinism**: are code, config, schema and flag
versions surfaced in the signals? (`Output = F(code, config, state, inputs)`
— without all four versioned, a replay cannot reproduce production, so this
is a precondition of dimension 7, not a nicety.)
Ask: which state transitions MUST be observable for 3am debugging. **Not**
whether the service is headless — that is derived from the repo, and asking
it is the rule against asking what you can derive being broken in the one
place it is easiest to break.
Row: contract checked mechanically or documentation-only; build/config
identity surfaced or absent; profiles collected continuously in production or
on demand only; tracing warranted (with the deriving signal named) and wired,
or declined (with the deriving signal named) — and if declined, whether
inbound carriers are still continued and outbound calls still injected.

**Profiling is the fourth signal, it is CONTINUOUS, and every service owes it
— headless ones included.**

Metrics say a latency moved. Traces say which span it moved in. Neither says
which code did it, and that answer decays faster than any other: by the time
somebody reproduces the regression, the process that had it has been
redeployed. A profile is only useful if it was already being taken.

The reference result is fleet-wide continuous profiling: a sampling profiler
left running everywhere, at an overhead low enough that nobody has to decide
whether to switch it on — Ren, Tune, Moseley, Shi, Rus and Hundt,
"Google-Wide Profiling: A Continuous Profiling Infrastructure for Data
Centers", IEEE Micro 30(4), 2010 (DOI 10.1109/MM.2010.68). The property worth
copying is the unconditional collection, not any particular implementation:
the OSS system built to that shape today is Grafana Pyroscope, named the way
this file names Kayenta and TLA+ — as the thing to look at, not as the thing
to require. Anything that keeps timestamped, symbolized profiles you can
retrieve for a past window and diff across a deploy satisfies this.

**Three vacuous forms, and this framework's own probe currently accepts the
first one:**

- **An endpoint is not a profile.** `net/http/pprof` on a debug port means a
  profile can be taken by whoever happens to be logged in while the incident
  is live. It says nothing about last Tuesday. The probe's `profiling` row
  asks for a capture script plus a live endpoint — that is the on-demand
  half, it is worth having, and it is not this.
- **A benchmark profile is not a production profile.** `benchmarks/profile.sh`
  profiles the workload you wrote on the hardware you had. Production
  allocates differently, and the entire reason to profile is that you were
  wrong about where the time went.
- **A profile with no build identity is unreadable.** Comparing across a
  deploy requires knowing which binary produced each side, which is
  dimension 11's version record pointed at the fourth signal. A profile store
  with no build label holds artifacts nobody can attribute.

"Headless services are exempt" is the specific mistake this entry rules out.
A batch job that got 40% slower has exactly one useful artifact — a profile
of the run that was slow — because there is no request to trace and no
dashboard that names the loop.

Inventory specifically: whether profiles are collected continuously in
production (always-on sampling, shipped to a store with a retention window)
or only on demand; which types (CPU, heap, goroutine/thread, mutex, block,
alloc); the sampling overhead MEASURED rather than assumed; whether a profile
can be retrieved for a named past window and a named build; when anyone last
read one.

**Tracing is CONDITIONAL — and the condition is DERIVED, never asked.**

A distributed trace is a causal join across process boundaries. A service
nothing calls has nothing to join to, so requiring "a tracer wired in `cmd/`"
of every service — as this framework's own standing instruction did — is a
requirement a queue consumer, a cron job or a daemon can satisfy only by
emitting root spans nothing can parent. That is not observability. It is the
3132-traces-of-one-span failure measured below, reached deliberately instead
of by accident.

So "does this service owe distributed tracing" has an answer sitting in the
repo, and the derivation that reads it off is `mechanism-derivation.md` §8: a
listener serving routes that are not the health/metrics/pprof surface,
handlers registered for them, an inbound port declared in the deployment
artifact, an extractable carrier arriving with the work — against a poll
loop, a ticker, or a `main` that runs once and exits. **Derive it. Ask the
human only when the signals contradict each other**, which in practice means
a consumer that also exposes an admin or submit endpoint (§9 asks about that
same port from the authentication side).

Three things a decline does NOT excuse, because collapsing them into "no
tracing" is how this correction gets over-applied:

- **Continuation.** A consumer whose producer stamped trace context onto the
  message is not the start of anything — it is the middle of somebody else's
  trace, and dropping the carrier there is where most real traces end.
- **Egress injection.** A headless service that calls anything still injects,
  or it truncates the trace of everything downstream of it.
- **Correlation.** Every service owes a join key across its own signals — a
  run id, a job id, a message id — whether or not it is a W3C trace id. That
  obligation is universal; only the *distributed* half is conditional.

**Wiring cannot be grepped.** A tracer, a metric or a hook that is imported,
constructed, or merely defined satisfies every text search you can write and
still never runs: a discarded variable, a helper nobody calls, and a contract
test's own call sites all match. Three successive tightenings of this check were
each fooled by the next shape. Treat a grep as an existence signal and nothing
more — the only evidence that instrumentation REACHES production is a test that
exercises the entrypoint's own construction path, or the signal appearing in a
real environment. Say which one you have.

**A span is not a trace.** The question a tracing check must ask is not "are
spans emitted" but "can two spans ever end up in the same trace". Measured on
a service that passed every other tracing check — tracer wired, spans reaching
the backend with full attribute fidelity, `RecordError` firing in production on
exactly the declared condition, contract test green:

    tempo_distributor_spans_received_total  3132
    tempo_ingester_traces_created_total     3132

One trace created per span received. Nothing joinable to anything. A
`traceparent` sent with a real request produced a 404 for that trace id — no
propagator was ever installed, so the global one was OTel's no-op and the
header was silently discarded.

Two rules, both cheap:

- **Check the precondition mechanically**: a service that starts spans and
  talks to anything else needs a propagator installed and context injected
  outbound, or a trace can never cross a process boundary. Absence of all of
  it is proof of the defect; presence is only necessary, so do not let the
  check claim more.
- **Guard the fix, not just the bug.** The specific defect that produces this
  — an adapter that calls `StartSpan(ctx, …)` and DISCARDS the returned
  context — was found, fixed, and then re-introduced verbatim in an audit with
  the full suite still green, because the test that nominally guarded it also
  discarded the context it was testing. A test that asserts a span's NAME and
  attributes proves nothing about propagation. Assert that the returned context
  CONTAINS the span, and that a child's parent is the expected span.

**Telemetry that reports its own failures through telemetry is a feedback
loop.** OpenTelemetry's error handler is PROCESS-GLOBAL: `otel.SetErrorHandler`
is one handler for every OTel SDK in the process. Route it through the
application logger while that logger also exports over OTLP, and a collector
outage becomes self-sustaining -- each failed export logs a warning, each
warning is a log record that tries to export, that export fails, and it logs
again.

Measured, not imagined: **19 export attempts and 19 WARN lines in 20 seconds
from a single seed log line, with zero traces exported.** The service was
busy talking to itself about being unable to talk.

So: the handler that reports a telemetry failure must write somewhere that
does NOT export -- stderr, or a logger built with no bridge. And the message
must not name a signal the global handler cannot identify, because one handler
serves traces, metrics and logs alike and cannot tell you which one failed.

The general rule underneath: **an error path must not depend on the subsystem
that is failing.** It is the same shape as logging a disk error to disk, and it
is easy to build by accident precisely because wiring telemetry failures into
the good logger looks like the tidy choice.

**Logs are a signal with a contract, not a debug afterthought.** Three things
recur, and all three are invisible to a passing test suite:

- **No handler configured.** A service can have tracing, dashboards and alerts
  wired and still emit unstructured text to stderr, because nothing forces a
  structured handler to be installed. Check the composition root for an
  explicit handler, not for the presence of log calls.
- **Logs that do not correlate.** In Go, `logger.Info(...)` silently drops the
  trace context; only the `*Context` variants carry it. A repo can be fully
  traced and have ZERO correlated logs. Grep for the ratio of `Info(` to
  `InfoContext(` — a service with none of the latter has no correlation
  regardless of what its exporter config says.
- **Attribute names, and the rewrite nobody warns you about.** Loki and
  Prometheus silently replace characters outside `[a-zA-Z0-9_:]` with `_`, so a
  key written one way is queried another and nobody gets an error — only zero
  results.

  The trap is the scope. It is natural to conclude "that only applies to LABEL
  names, so log attributes are free" — and that is **wrong for any service
  shipping logs over OTLP**. Measured against a live Loki 3.x: a service
  emitting `entry-id` and `idempotency-key` had them stored as `entry_id` and
  `idempotency_key`, because Loki promotes record attributes to structured
  metadata under the same naming rules. LogQL cannot even parse the emitted
  spelling — `` | `entry-id`="…" `` is a syntax error, while `| entry_id="…"`
  returns the line.

  So: whatever the house convention, if the logs land in Loki the operator
  greps one spelling in the source and must type another in Grafana. Prefer
  **one case everywhere** — snake, matching metric names, label names and OTel
  semantic conventions — unless the owner accepts that cost explicitly. Verify
  it rather than reasoning about it: emit one line and read back what the store
  actually holds.

For Go specifically, the researched default is `log/slog` bridged to OTel with
`contrib/bridges/otelslog`, and `sloglint` (`context: all`, `forbidden-keys`,
a `key-naming-case`) to make all three of the above compile-time rather than
review-time. zap's published speed advantage does not survive a like-for-like
re-run; see the consuming repo's decision memo before re-litigating it.

**Log levels are not portable and mostly should not be a gate.** RFC 5424 says
its own severity table is non-normative; OTel's SeverityNumber inverts syslog's
direction and adds TRACE. What IS worth checking: a service whose ERROR call
sites outnumber everything else combined is usually logging handled errors, and
each of those is a line nobody can act on.

## 9. Security
Inventory: authz/authn surface, policy-as-invariant candidates, secret
scanning (on which triggers), dependency vulnerability scanning, SBOM,
artifact signing/provenance, secretless presubmit, network policy; a
semantic/dataflow SAST pass on top of whatever the general linter already
does (taint from an untrusted input to a sink — injection, deserialization,
SSRF — is a different question from style, and a linter answers style);
policy-as-code checks on the deployment artifacts themselves, not only their
CI (the same class of validation `actionlint` already applies to workflow
files, extended to whatever this repo ships — Kubernetes manifests,
Terraform, compose files: an overly permissive RBAC role or an open security
group is invisible to every gate above and is exactly the kind of defect this
dimension exists to catch).
Ask: which authorization rules are invariants ("A can never reach B"); what
must never be reachable from outside.
Row: each supply-chain gate present/absent; policy invariants declared or
not; SAST dataflow coverage present or linter-only; IaC/manifest policy
checks present or absent.

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

**A stall is not a failure this dimension catches unless something measures
PROGRESS against an independent denominator.** The worst outage this framework
has produced was not a mode that failed to recover — it was a mode nothing
detected, because every signal read healthy while the service did no work at
all: liveness green, readiness green, zero errors, zero alerts, and a consumer
that had silently stopped consuming and was accepting and discarding writes.

The mechanism is worth stating exactly, because it is general and it is easy
to build by accident. A progress signal derived from **work done** freezes at
a plausible value when work stops. Consumer lag computed as
`highest_seen - cursor` reads 0 when you are caught up **and** 0 when you are
dead, and there is nothing in the number to tell the two apart. The same shape
appears in "records processed since last poll", "queue depth" measured from
the consumer's own buffer, and any rate computed over a window in which the
producer also stopped.

So: **the denominator must come from the source, not from your own
consumption.** Probe the upstream's head independently of reading from it —
cheaply, since it is a liveness question and not a data one. Then the
comparison has a fixed point of reference, and impossible readings become
available as evidence: a head BELOW your cursor cannot happen in a monotonic
stream, so observing it is proof the upstream's history was discarded, not a
race to be smoothed over.

Two rules follow, and both are cheap:

- **A metric that is only correct while the system is healthy is worse than no
  metric**, because it reads plausible in precisely the situation you consult
  it. Ask of every gauge: what does this show when the thing it measures has
  stopped entirely? If the answer is "the same as healthy" or "zero", it is not
  a progress signal.
- **Readiness must include a progress gate, not only correctness gates.** A
  health check whose gates all ask "is my state valid" will pass forever on a
  service that is valid and idle. At least one gate must ask "am I still
  moving", and it must be able to answer no.

Row: consumption/progress measured against an independently probed source, not
against the consumer's own high-water mark; readiness carries at least one
progress gate; the "impossible" reading is treated as evidence rather than
clamped away.

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

## 16. Wiring — mechanisms are DRIVEN, not merely present

A mechanism nothing calls is indistinguishable from one that does not exist,
except that it passes its own unit tests — so the suite reports it as covered.
That makes it **worse than absent**: absence is visible, dead wiring is not.

This dimension exists because the same defect appeared FOUR times in one repo
that was passing every other gate. A tracer, instrumented, with a green span
contract test, never constructed in `cmd/`. Operational counters, implemented
and tested, never wired into the metrics surface — so the series read zero in
production while the underlying value climbed, and a derived lag went
*negative*: a healthy-looking impossible number rather than a crash. A durable
outbox constructor, tested, absent from the composition root, which wired the
in-memory form instead. And a `Reconcile` with passing tests and no caller, so
a journaled entry whose sink was down stayed pending for the life of the
process.

Inventory: every mechanism the spec claims, paired with the symbol that proves
production reaches it. What grows this list is the same thing that grows the
system — if you added a mechanism, you owe a line here.

Ask: nothing. This one is not a semantic question for the human; it is
mechanically checkable, and asking would only invite the answer "yes of course
it is wired", which is what everyone believed all four times.

Row: how the wiring is PROVEN — and note what does not count. Neither a unit
test of the mechanism nor a grep of the source can answer this. A test links a
different binary; a grep matches comments, discarded assignments, helpers that
are themselves never called, and the mechanism's own tests. The probe reads
the LINKED ARTIFACT instead: Go eliminates code unreachable from `main`, so a
symbol's presence in the shipped binary is evidence production reaches it, and
its absence is proof nothing does.

Two things learned building that check, both worth keeping:

- **Disable inlining when you look.** A small function production really does
  call can be inlined into its caller, and an inlined symbol is missing from
  the table in exactly the way an eliminated one is. The first draft reported
  a correctly-wired tracer as dead. A row that cries wolf is a row somebody
  switches off, so the false positive mattered more than the true ones.
- **Match the symbol exactly, not as a substring.** Caught by mutation:
  swapping a real tracer for `NewNoop()` left the declared `New` matching as a
  prefix of `NewNoop`, and the row passed a service whose tracing had just
  been turned off.

The limit, stated because a gate that overclaims is the defect this framework
exists to name: the linker keeps every method of an interface the program
uses, since dynamic dispatch could reach any of them. A never-called method
belonging to a used interface will survive and this row will pass it. Plain
functions and methods outside any used interface are eliminated precisely.
That covers the four defects above; it is not a universal reachability proof.

## 17. Progressive delivery and design-time verification

Two different verification moments, grouped here because both sit OUTSIDE the
suite that runs before merge: one runs AFTER deploy, against real traffic;
the other runs BEFORE a single line of implementation exists.

**Canary analysis.** Dimension 10 already asks whether canary analysis
exists and whether it is automated. This entry asks what "automated" is
actually verifying, because the two things it gets confused with are cheaper
and are gates in name only:

- **A timer is not an analysis.** "Wait ten minutes, then promote" catches
  nothing that does not fail in the first ten minutes, and a regression that
  degrades slowly at 1% traffic sails through it at every stage.
- **A human staring at a dashboard is not automated**, even where a human is
  genuinely required to approve — the tier policy already asks for that ack
  at T0. The analysis and the approval are different steps, and collapsing
  them hides whether the number that got approved meant anything.

The property worth gating on is a STATISTICAL comparison of the canary
population against the baseline population, on the metrics the service
already declares (dimension 8's invariant counters and SLOs, not a bespoke
set invented for the rollout), with a defined confidence threshold and a
defined promote/abort rule — not "no alerts fired," which is the
absence-of-evidence failure this framework refuses everywhere else. The
canonical reference implementation is Netflix's Kayenta, which scores a
canary against baseline with a Mann-Whitney U test over per-metric confidence
intervals rather than a fixed threshold on each metric in isolation; the same
team's "Rapid Regression Detection in Software Deployments through
Sequential Testing" (arXiv:2205.14762) frames the promote/abort decision as
sequential hypothesis testing specifically to shorten time-to-detection
without inflating the false-abort rate — the two failure directions of this
gate are symmetric: an analysis too eager to abort erodes trust and gets
overridden by hand, which is the same as not having one.
Inventory: how a canary stage decides to promote or abort today (elapsed
time, human judgment, automated statistical comparison); which metrics and
invariants feed that decision; the traffic split and population sizes; the
abort path and whether it is rehearsed.
Ask: which invariants and SLOs must hold on the canary population before ANY
promotion; what confidence or sample size the comparison needs at this
service's traffic volume to mean anything (a canary at 0.1% traffic for 60
seconds has no statistical power, whatever dashboard it produces).
Row: promotion decided by a statistical comparison against baseline, by
elapsed time, or by unaided human judgment; which metrics feed it; abort path
tested or assumed.

**Design-time model checking.** Every other dimension in this framework
verifies code that already exists. This entry is the one exception: for the
highest-risk slice of a system — a concurrent or distributed protocol whose
correctness depends on interleavings no unit test enumerates, not the system
at large — the cheapest place to find a race, a deadlock, or a violated
invariant is before the first line of implementation, against a model of the
protocol (TLA+ is the canonical tool here — Lamport, TOPLAS 1994 — and its
best-known industrial result is AWS finding bugs in production DynamoDB and
S3 subsystems that years of code review and testing had not surfaced, CACM
2015).

This is deliberately scoped narrow. It sits one level above mutation testing
(dimension 2) on the same fault-sensitivity spectrum: mutation finds what
your tests fail to catch in code that already exists; this finds what your
DESIGN fails to rule out before any code exists. Modeling the whole system is
not the claim — mandating it broadly is how a gate like this earns a
rubber-stamp model nobody actually checks against the implementation, which
is worse than not having one. Reach for it exactly where a bug would be a
whole class of interleavings rather than one line.

Inventory: which subsystems are genuinely concurrent/distributed protocols
(leader election, consensus, distributed locking, exactly-once handoff,
multi-step sagas) rather than ordinary sequential logic; whether any of them
has a written model and what it has been checked against.
Ask: does this system have a protocol whose failure mode is an interleaving
rather than a line of code — and if so, was the model written before the
implementation it is meant to constrain, or reconstructed after?
Row: protocols requiring modeling identified, or none exist and that is
stated explicitly; which have a checked model and which do not; each model
checked against the CURRENT implementation, or known to have drifted.

## 18. Static analysis — semantic dataflow (SAST)

Dimension 9 already asks whether a semantic/dataflow SAST pass exists on top
of whatever the general linter does. This entry exists because that
distinction is not academic pedantry — it is the difference between a gate
that finds the vulnerability class this framework cares about and one that
only looks like it does.

A controlled study running standard SAST configurations against codebases
with confirmed, real vulnerabilities found that the default rulesets missed
**61.2% of the vulnerabilities actually present** ("Semgrep\* — Improving the
Limited Performance of SAST Tools", ACM/ESEM 2024, DOI
10.1145/3661167.3661262). The gap is not tool immaturity so much as scope: a
pattern-matching or regex-style linter answers "does this code look like a
known-bad shape", which is a style question with a security label on it. A
dataflow-capable engine answers a different question — can data that
originates at an untrusted input (a request body, a query parameter, a
message payload) reach a sensitive sink (a query, a shell invocation, a
deserializer, an outbound URL) along some path through the program — and
that question requires tracking taint through assignments, calls and
returns, which a linter operating one line at a time structurally cannot do.

**Zero findings is not evidence of no vulnerabilities; it may only be
evidence that the tool in use cannot see the class of bug being asked
about.** The vacuous version of this gate is indistinguishable from the real
one in a passing CI run — both show a green check — so the audit question is
never "did SAST run" but "did a dataflow-capable engine run, and can it name
the taint sources and sinks it actually tracks for this codebase's
language(s)". A dataflow engine configured with zero custom sources/sinks for
a codebase's actual untrusted-input surface (an internal RPC treated as
trusted, a message-bus payload never declared as a source) is the same
vacuity failure in a different shape: it will run clean forever regardless of
what the code does.

Inventory: what runs today — general linter only, a dataflow/taint-tracking
engine, or both; which languages and which parts of the codebase are in its
scope; whether the sources and sinks it tracks are the codebase's actual
untrusted-input surface (declared explicitly) or only the tool's stock
defaults; whether findings block the merge or are advisory; the triage
backlog and its age.
Ask: nothing structural — this is mechanically checkable from the tool's own
configuration and coverage report. What may need a human: which boundaries in
THIS codebase are the untrusted-input sources the dataflow engine should be
told about, where that is not obvious from the language's own conventions
(e.g., an internal service treated as trusted by convention but reachable
from outside the trust boundary in practice).
Row: dataflow-capable SAST present or linter-only; declared source/sink
coverage against the codebase's actual untrusted-input surface, or stock
defaults only; blocking or advisory; findings triaged or backlogged.

## 19. Schema evolution and breaking-change detection

This is industry practice, not an academically-backed dimension — no paper
is cited here, deliberately, because none was given and none should be
invented. It earns a place in this framework because it is the mechanical
half of a semantic event `prod-spec` already detects and routes:
`changes_schema` pulls a requirement set into a change plan's
`required_evidence`, and this dimension is what that requirement set should
actually demand for anything published on an event-driven surface — Avro,
JSON Schema, protobuf, or an equivalent wire format with independent readers.

This is deliberately distinct from two entries that already touch schemas
and does not duplicate either: dimension 5's `compatibility` clause is about
whether an INTEGRATION test exercises a real broker's registry (fidelity —
does the check run against the real thing); dimension 14's
`published_contract` is about whether an EMITTED payload to an external
audience is versioned and pinned by a test (the audience-facing contract,
checked at the point something ships). This dimension is about neither of
those — it is about whether a **breaking change is caught mechanically, in
CI, at merge time, before it lands**, as a distinct gate rather than as a
side effect of an integration test happening to notice.

The distinction that separates a real gate from a vacuous one here: a schema
check that only diffs the CURRENT PR's schema file against itself (or
against nothing) passes trivially on every PR, including the one that
deletes a field a live consumer reads. A real check computes compatibility
between the proposed schema and the schema version(s) actual consumers are
running against — full, backward, or forward compatibility per the
declared policy — and fails the merge when that computation says a consumer
would break, not when a human notices a diff in review.

Inventory: which schema formats this repo publishes or consumes on an
event-driven surface; whether a compatibility check runs in CI on every PR
that touches a schema, and against what baseline (the immediately prior
version, the registry's live version, or all versions still in use by known
consumers); whether the check is advisory or blocking; whether it fires only
on schema-file changes or can be silently bypassed by a change that alters
serialization behavior without touching the schema file itself (a default
value change, a type-widening change in application code that the schema
technically still allows).
Ask: what compatibility mode this event-driven surface has actually chosen
(this may already be answered by dimension 5's `compatibility` question —
this entry asks whether that policy is ENFORCED mechanically, not merely
declared); which consumers are on an old schema version today and would be
the first to break.
Row: compatibility check present in CI or absent; blocking or advisory; the
baseline it diffs against (immediately-prior version only, or every version
still in use); consumers named or their currency unknown.

## 20. Chaos in production, and consistency checked against a history

Two instruments that both look like §7 and are neither.

**Chaos experiments are not a CI fault-injection suite.** §4's matrix has a
`chaos` lane, §7 inventories a fault-injection harness, and §13 requires a
test that INDUCES a failure and times the return. All three run before merge,
against a hermetic or containerized system, on the faults the author thought
of. Basiri et al. define the discipline differently, and the difference is
the whole value: **experiments run against a system carrying production
traffic, each stated in advance as a hypothesis about a steady-state metric,
drawn from real-world event classes, automated to run continuously, with a
minimized blast radius** ("Chaos Engineering", IEEE Software 33(3), 2016, DOI
10.1109/MS.2016.60). A fault-injection suite verifies the faults you
enumerated. A chaos experiment is a claim about the ones you did not.

Its vacuous forms:

- **A chaos lane containing no fault.** This framework's own template ships
  `make chaos` as `-race -count=N` and says so in a comment — an honest
  placeholder, and a repo that leaves it there has a lane whose NAME is the
  only chaotic thing about it.
- **An experiment with no steady-state hypothesis.** "Kill a pod and see what
  happens" produces a story, not a result: with no metric declared in advance
  and no threshold that decides pass from fail, the outcome is whatever the
  person watching concluded, and nothing can regress against it later.
- **A blast radius that is an intention.** "We only run it at 1% of traffic"
  is a property of the experiment only if something enforces the split and
  something aborts on the hypothesis breaking. Otherwise it is the same
  missing-abort-path failure §17 names for canaries.

**Consistency is the second half, and it needs a different instrument.** This
framework asks every stateful capability to declare its consistency
semantics — `source_of_truth`'s `consistency_semantics` obligation, and the
`semantics.consistency` line in the spec. Nothing in the standard set then
checks that declaration. Recovery tests ask whether the system comes back;
they never ask whether what it served *while* partitioned was linearizable.
The instrument for that is a recorded HISTORY of concurrent client operations
checked against the model, which is what Jepsen does generally and what Elle
does for transactional isolation specifically — recovering the dependency
graph from ordinary client-observable reads and writes rather than requiring
the store to be instrumented or to report on itself (Kingsbury & Alvaro,
"Elle: Inferring Isolation Anomalies from Experimental Observations", PODC
2021, DOI 10.1145/3465084.3467483).

Its vacuous form is the sharpest here: **a consistency model declared in the
spec and checked by nothing.** One line saying `consistency: linearizable`
reads as rigour, costs nothing, and is true right up to the first partition.
A history checker that runs only against a healthy single node is the same
failure with a test suite attached — the anomalies it exists to find are
reachable only under partition, failover or clock skew, so a green run
without one of those is a green run of nothing.

Inventory: whether any fault is injected against a system carrying real
traffic, or only in CI; per experiment, the steady-state metric, the
hypothesis, the abort condition, and what enforces the blast radius; whether
experiments run on a schedule or were run once and written up; the declared
consistency model of every stateful capability; whether any check exercises
that model against a recorded history under partition/failover, and whether
the checker infers anomalies from client-observable operations or trusts the
store's own reporting.

Ask: which failure classes are real-world for THIS deployment (zone loss,
dependency brownout, leader failover, clock skew) rather than theoretically
possible; what steady-state metric an operator would accept as "the system is
fine"; the maximum acceptable blast radius and who authorizes an experiment
at it; whether each declared consistency model is a promise made to a
consumer or an internal description of current behavior.

Row: chaos experiments run against production traffic, run in CI only, or
absent; each experiment's steady-state hypothesis and abort path declared or
absent; the declared consistency model checked against a recorded history
under an induced partition, or declared only.

## 21. Consumer-driven contracts

Ian Robinson, "Consumer-Driven Contracts: A Service Evolution Pattern"
(martinfowler.com, 2006). Industry pattern with a written source, not an
empirical result — cited as the pattern's definition, nothing more.

Three existing dimensions touch this surface and none of them covers it. §5
asks whether an integration lane exercises a real dependency (fidelity). §14
asks whether an emitted payload is versioned and pinned by a test
(provider-side, at the point of shipping). §19 asks whether a breaking schema
change is caught mechanically at merge (the gate). All three are written from
the PROVIDER's side, and they share one blind spot: **the provider is also
the author of the expectation.** A pinned shape is pinned to what the
provider decided to emit, so a provider can rename a field and update its own
pin in the same commit with every gate green — and the consumer reading that
field finds out in production.

Consumer-driven contracts invert the authorship. The expectation is written
by the CONSUMER, states only the subset of the surface that consumer actually
depends on, and is verified inside the PROVIDER's build. What that buys is
not more testing; it is a different oracle. The provider learns which fields
have a reader before deleting one — and, the half that pays for the
ceremony, which fields have NO reader, which is the only mechanical way this
framework offers to SHRINK a published surface instead of accreting it
forever.

Vacuous forms:

- **The provider writes the consumer's contract.** Both sides of the check
  now have one author, and it degenerates into §14's pin with more
  infrastructure around it.
- **Verification against a mock of the provider.** A consumer test passing
  against its own stub proves the stub matches the expectation. The
  verification has to run in the provider's build against the provider's real
  handler, or it is checking a fixture against a fixture.
- **A stale contract nobody re-publishes.** A consumer that changed what it
  reads and did not update its contract leaves the provider defending a shape
  nobody wants, while believing it has coverage of the shape that is now
  load-bearing. Contracts need the currency question every liability in this
  framework has: last published when, by a consumer still deployed?
- **Contracts only for the consumers you own.** The internal consumer in the
  same monorepo is the one you can fix in an afternoon. §14's whole argument
  is that the expensive audience is the one you cannot.

Inventory: named consumers per published surface (§14 already asks who they
are; this asks whether each has expressed WHAT it reads); which consumer
expectations exist as executable artifacts and where they live; whether
provider verification runs in the provider's CI on every change to the
surface, and whether it blocks or is advisory; the age of each contract and
whether its author is still deployed; fields on the published surface that no
contract claims.

Ask: for each consumer, is it inside the trust boundary (fixable by the same
team on the same day) or outside it; which consumers are unwilling or unable
to publish a contract at all, so their expectation must be inferred or their
surface frozen.

Row: consumer contracts present per named consumer, or absent; verified in
the provider's build, blocking or advisory; contract currency (last
published, consumer still live); unclaimed fields on the published surface
identified or unknown.

## 22. SLO and error budget as a MECHANISM

Beyer, Jones, Petoff and Murphy (eds.), *Site Reliability Engineering*
(O'Reilly, 2016) — the error-budget formulation this entry uses.

SLOs already appear in this framework three times, and every appearance is
declarative: §6 inventories "declared SLOs" and asks whether an absolute SLO
is asserted anywhere; §10 lists "alerts and SLOs" among operability
artifacts; §17 scores the canary against "the metrics the service already
declares". None of them asks the question that turns an SLO into an
instrument: **what CHANGES when the objective is missed.**

The error budget is that mechanism. "99.9% over 30 days" is also the
statement that roughly 43 minutes of unavailability are BUDGETED — spendable,
deliberately — and the remaining balance is a number a release decision can
read. Without the budget, an SLO is a sentence in a document. With it, it is
the input to a policy.

Vacuous forms, and this framework's own scaffold demonstrates the honest way
to be short of one:

- **An objective with no SLI behind it.** A number asserted against a
  quantity nothing measures. `prod-new`'s template says exactly this about
  its outbox-latency objective — "the SLI itself needs a metric first" — and
  saying so is the correct answer; inventing the objective anyway is not.
- **An SLI measured from the server's own success counter.** A request the
  load balancer dropped never reaches the denominator, so availability is
  computed over the traffic that worked. This is §13's progress-metric
  failure in a different costume: a number that is correct exactly while the
  system is healthy. State the measurement VANTAGE POINT, and prefer one
  outside the process being measured.
- **A budget nothing consumes.** A burn-rate panel that no release gate, no
  alert and no prioritization decision reads is a dashboard. The mechanical
  question is which decision the remaining balance changes, and where that is
  written down.
- **Paging on the SLI instead of the burn rate.** A page for every dip is a
  page nobody reads by week three; burn-rate alerting at two windows (a fast
  one for the outage, a slow one for the drip) is the shape that survives.
- **An objective set to what the system already does.** Derived from last
  month's measured availability, it cannot be missed and therefore decides
  nothing. The objective comes from what a consumer needs, which is why it is
  the one number in this dimension a human must supply.

Inventory: per user-facing capability, the SLI (the exact query, and the
vantage point it is measured from), the objective, the window, and whether
the window rolls or resets; whether remaining error budget is computed
anywhere and by what; burn-rate alerts and their windows; the policy the
budget feeds — what is not allowed to ship once it is exhausted; whether that
policy has ever actually fired.

Ask: what a consumer of this service actually needs (a product decision, not
an engineering measurement); who may spend the budget and who declares it
exhausted; which capabilities have no meaningful percentage form at all — a
correctness invariant is 100%-or-page, and saying so is a complete answer,
which is how this framework's own units-conservation SLI is written.

Row: SLI defined with its measurement vantage point, or an objective with no
SLI behind it; error budget computed or not; burn-rate alerts at more than
one window or single-window/absent; the exhaustion policy declared, and
whether anything enforces it.

## 23. Dependency currency and version pinning

**Industry practice, no paper.** Dependabot, Renovate and their equivalents
are a widely adopted operational discipline with no academic result behind
them that this framework can cite, and inventing one would be worse than
leaving the entry uncited.

Two properties in tension, which is why they are one dimension. A build must
be REPRODUCIBLE — the same inputs at a later date produce the same artifact —
and a deployment must be CURRENT — the version running is not one with a
published advisory. Pinning alone buys the first and quietly destroys the
second: a lockfile is a commitment to keep using exactly the version that
will eventually be the vulnerable one. Automation alone buys the second and
destroys the first.

What is already covered, and where the hole is: §9 inventories dependency
vulnerability scanning and the tier policy requires it, so a KNOWN vulnerable
dependency is caught. §11 asks whether the environment is versioned and
recoverable for a past run. Neither asks whether anything moves a dependency
forward on a cadence, and neither looks at the versions of the TOOLS the
gates themselves run on. That second half is the sharper one here, because in
this framework the gates ARE the standard: a workflow step written
`actions/checkout@v4` is pinned to a MUTABLE tag its owner can repoint, so
the trusted computing base of every gate in that repo is whatever the tag
resolved to this morning. Named against this framework rather than in the
abstract: `prod-new`'s CI template pins its Go tools to exact versions
(`golangci-lint@v2.12.2`, `govulncheck@v1.7.0`) and its third-party actions
to floating major tags (`actions/checkout@v4`, `actions/setup-go@v5`,
`gitleaks/gitleaks-action@v2`). A framework that files this as a finding
elsewhere and not against itself is doing the thing it exists to stop.

Vacuous forms:

- **A lockfile with no update cadence** — reproducible and rotting. The
  vulnerability scanner finds it eventually, which means the first signal is
  an advisory rather than a routine bump.
- **Automated PRs nobody merges.** An open bot backlog is not currency; its
  AGE is the measurement, and a bot opening PRs into a queue is indexing the
  debt rather than paying it.
- **A pin to a mutable tag.** `@v4` and `:latest` are not pins. Only a commit
  SHA or a content digest is.
- **Auto-merge on green, where green is a gate the update itself can
  weaken.** An update that changes a linter's ruleset, a scanner's database,
  or a tool a gate shells out to is a change to the ORACLE, and it needs the
  review a change to the gate would get. Auto-merging it is letting the thing
  under test approve itself.

Inventory: which manifests are locked, whether the lockfile is committed, and
whether CI enforces it rather than regenerating it (`--frozen-lockfile`,
`--locked`, `go mod verify` / `-mod=readonly`); whether an automated update
mechanism exists, its cadence, its grouping and its auto-merge policy; open
update-PR count and the age of the oldest; every third-party ACTION and every
TOOL the gates invoke, and whether each is pinned to an immutable identifier
or a mutable tag; whether a build from a past commit still resolves today.

Ask: which dependency classes may auto-merge on green, and which need a human
because the update can change what a gate MEASURES; the acceptable lag for a
security update versus an ordinary one.

Row: lockfile committed and CI-enforced, or advisory; update automation
present with a stated cadence, or manual; age of the oldest open update PR;
gate tooling and third-party actions pinned to immutable identifiers, or to
mutable tags.

## Cross-dimension metrics worth computing because they are nearly free
- **Oracle gap** per package: structural coverage MINUS mutation score. A big
  gap localizes weak assertions better than either number alone; both inputs
  already exist (coverage as SIGNAL, mutation as TREND). Report per package in
  the trend lane, never as a gate.

## A name that falls through to a global namespace EXECUTES something

Ask of every script: what happens when a name in it is not defined? If the
answer is "the lookup continues somewhere else", a typo is not an error — it is
a call to whatever else answers.

**Measured 2026-08-20.** A scenario script called `say "SIGKILL ..."` six times,
meaning a local narration helper beside its real `step` / `note` / `good` /
`bad`. It never defined `say`. Bash resolved the name on `PATH`, and on macOS
that is `/usr/bin/say`: the script **spoke its status lines aloud through the
speakers**. On Linux the same lines were `command not found` on stderr. The exit
code was 0 either way, and the human who heard a voice had no idea it came from
a shell script.

Nothing in the usual kit sees this. `set -u` covers unset *variables*, not
commands. `set -e` sees a *successful* `say`. `bash -n` is syntax only. And a
linter cannot know the name was not meant, because calling an external binary is
ordinary.

**The guard: an explicit allowlist of external commands**, checked against every
word in command position that is neither defined in the same file nor a
builtin. The detail that makes it quiet enough to survive contact with real
scripts: **only report words that actually RESOLVE to an executable.** Prose the
regex sweeps up ("the", "cannot", "every") resolves to nothing and filters
itself out; the dangerous case is exactly the word that resolves, and the
message should name the path it would have run.

State what such a check cannot see — a command inside `$( )`, behind `xargs`, or
in a variable — in the script itself. A guard that implies more coverage than it
has is the vacuous gate wearing a useful gate's clothes.

## When a gate fires on something CORRECT, find the missing distinction

A red gate has two possible meanings and they need opposite responses: the code
is wrong, or the gate lacks a distinction the code legitimately relies on. The
second is rarer, and it is where the damage happens, because the cheapest way
out is to edit the code until the gate goes quiet.

**Measured 2026-08-20.** A citation checker enforces the rule that every `TestX`
named in a comment, doc or spec must exist — a citation to a deleted test is an
evidence trail that dead-ends and fails silently. It went red on a test header
whose prose explained what that test's **weaker predecessor** failed to catch.
The predecessor is deliberately gone. The sentence is the reason the replacement
exists. The gate could not tell a citation from a **tombstone**.

Three wrong fixes, in order of temptation:

1. **Delete the name from the comment.** Green in one edit, and it deletes the
   reasoning the comment exists to carry. Worse than the red gate, because
   afterwards nothing shows what was lost.
2. **Teach the checker to recognise prose** — "was named", "formerly",
   "predecessor". A clever matcher that silently stops matching one rewording
   later, which is the same vacuous-gate failure the standard exists to refuse.
3. **A blanket ignore list.** Rots into a mute nobody rereads.

**What works: an explicit registry whose entries COST something.** A retired-name
registry, plus two rules that stop it becoming a blanket mute:

- every entry must name a **replacement that exists** — otherwise the evidence
  trail merely dead-ends one hop later, the exact defect being guarded;
- a retired name that **exists again is a FAILURE** — resurrection means the
  exemption is now silently muting a live symbol's citations.

**Then prove the exemption did not blunt the gate.** After adding it, the same
checker immediately caught a genuinely dead citation in a README written minutes
earlier. That is the check to run after ANY exemption: *does the gate still
catch a real one?* An exemption you cannot demonstrate is narrow is a hole.

The general rule: when a gate fires on something correct, the question is never
"how do I make it stop" but **"what distinction does it lack"** — then encode
that distinction somewhere a human must justify each instance.

## Liabilities: read the RETIREMENT CONDITION, not just the evidence

A registry entry has two halves. The evidence says why the liability exists —
and it is written at the moment someone decided they could not fix it, so it
reads like a wall. The retirement condition says what closing it would take,
and it is usually the more useful half, because whoever wrote the entry had
just finished thinking about exactly that.

A feature flag is the paradigm case: it is a liability that already carries
its own retirement condition — a TTL — so a flag with no expiry is not a
lighter-weight liability than the others in this section, it is one that has
already dropped the half that makes it closeable.

**Measured, on one repo, in one session: five liabilities were characterised as
"external constraints — not closeable from this side". Four were closeable, and
three of those four had the fix written in their own retirement condition.**

  - "the upstream feed's history retention is undocumented" — condition asked
    for cursor-reset DETECTION, which had already shipped.
  - "fsync is untested; that needs a machine kill" — condition asked for
    `docker kill` on a container, and the stack was running.
  - "losing the outbox log silently replays all history" — condition offered
    "refuse to boot when the event log is non-empty and the outbox log is
    absent". One `stat()`.
  - "the venue has no idempotency; that is their contract" — condition named a
    reconciliation pass that matches our own submitted intents against what the
    venue published. That needs no cooperation from the venue at all.

The failure mode is a framing error, not laziness: asking whether the
DEPENDENCY can be fixed, when the question is whether the SYSTEM can defend
itself. A venue with no idempotency cannot be made idempotent — and a client
can ask it what it already has before retrying. An upstream that publishes no
epoch cannot be made to — and a consumer that already read message N knows what
N contained, so different bytes at the same id prove the history was replaced.

So, when triaging any liability:

- **Read the retirement condition first.** If it names a mechanism, the entry
  is a TODO wearing a constraint's clothes.
- **Separate "the dependency cannot do X" from "we cannot detect or defend
  against X".** The first is often true and rarely the whole question.
- **An entry with no retirement condition is itself a finding.** It cannot be
  discharged, only expire, which makes it a permanent excuse.
- Only after all three: if the residual is genuinely inherent, say what it is
  in one sentence an operator can act on, and make sure the code CHOOSES rather
  than drifting — for an ambiguity with no safe default, pick the direction
  whose worst case is the smaller loss and write down why.

**Two constants that describe one property must have the RELATIONSHIP
enforced.** A broker remembered a message id for 2 minutes while a queue would
hold an entry for 24 hours. Each value was defensible; together they meant a
retry after a long outage was accepted as new, and the stream carried the same
effect twice with nothing failing. Neither constant was wrong. The absence of a
test tying them was. Where two numbers in two packages encode one guarantee,
assert the ordering — in a neutral third package if importing one from the other
would be a cycle or a layering violation.

**Skipping something must not destroy the evidence for it.** A consumer that
cannot decode a message and advances past it is right — waiting is not recovery
— but the raw bytes are the one artifact nobody can reconstruct, and upstreams
routinely keep history in memory. File the payload BEFORE the decision that
moves past it: a crash between the two then leaves evidence with no decision,
which is recoverable, instead of a decision with no evidence, which is not.
