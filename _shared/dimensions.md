# The ten dimensions — the completeness checklist

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
Ask: what the system must guarantee across a restart (what may be retried,
what must NOT, what is reconciled); whether durable state exists at all (if
none, record reconciliation as N/A with that reason).
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

## Cross-dimension metrics worth computing because they are nearly free
- **Oracle gap** per package: structural coverage MINUS mutation score. A big
  gap localizes weak assertions better than either number alone; both inputs
  already exist (coverage as SIGNAL, mutation as TREND). Report per package in
  the trend lane, never as a gate.
