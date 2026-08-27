# verification/simulation — deterministic simulation, stage 1

One seeded schedule of ~500 operations and injected faults, driven through
the real app-layer orchestrator (`internal/app.Ledger`), asserting the
ratified invariants after every step. Run it:

```
make sim                 # the default seed — deterministic, byte-for-byte
SIM_SEED=42 make sim      # any other schedule
```

The seed is printed on every run and repeated in every failure message, so a
red run hands you the command that reproduces it. That is the whole property
being bought here, and it comes from FoundationDB's simulation testing (Zhou
et al., *FoundationDB: A Distributed, Unbundled Transactional Key-Value
Store*, SIGMOD 2021): FDB wrote the simulator before the database, ran the
whole system inside a deterministic single-threaded environment, injected
faults from a pseudo-random schedule, and got back the ability to **watch a
bug again on demand**. A randomized test that cannot tell you how to see its
failure a second time is a rumor, not a finding.

## What stage 1 covers

- **The real app layer.** `internal/app.Ledger` through its public
  `Deposit`/`Withdraw` surface, over the injected `Clock`, `IDGenerator` and
  `EventJournal` ports — the same three deterministic fakes
  `internal/app/ledger_test.go` injects. Nothing reaches into package
  internals.
- **A workload that mixes** first-time deposits and withdrawals,
  caller-supplied and generator-minted event ids, and deliberate overdraft
  attempts sized from the balance the ledger actually holds.
- **Two injected faults**, counted against a denominator rather than against
  the author's imagination. The standard's denominator for fault coverage is
  the capability-class checklist (`tier-policy.yaml`, `capability_classes`);
  this scaffold's one declared capability is `external_effect`, whose
  checklist has **nine** scenarios. This harness expresses the two with an
  app-layer analog — `crash_between_decision_and_effect` (the append failure
  and the restart after it) and `duplicate_response` (redelivery, seen from
  the inbound side). The other seven — `rejected`,
  `timeout_before_acceptance`, `timeout_after_acceptance`,
  `malformed_response`, `unavailable`, `extreme_latency`,
  `retry_on_unknown_state` — live at the adapter boundary this harness does
  not drive, and are covered by `internal/adapter/out/store`'s conformance
  kit. **2 of 9 here, 9 of 9 in the repo.**

  The two, in detail:
  - *durable-append failure*, which must leave committed state exactly where
    it was, nudge nothing, and leave the event id still admissible on retry;
  - *duplicate delivery* of an already-admitted event, byte-identical, which
    must be absorbed with no balance change, no version change and nothing
    appended.
- **State-replay restarts**: state is rebuilt from the surviving log with
  `internal/platform/eventlog.Rebuild` — the composition root's own boot
  fold, not a re-implementation — and a fresh `Ledger` continues over it.
- **Invariants after every step**: `units_conserved` against an independent
  `math/big` tracker, `duplicate_event_single_effect`, version against
  durable-log length, one relay nudge per durable record, and the app's own
  runtime violation counters still at zero. At each restart and once at the
  end, the whole log is folded from genesis and required to reproduce the
  in-memory state exactly (balance, version, applied-id set).
- **That the seed reproduces**, checked mechanically and not assumed:
  `TestSimulation_SeedReproduces` runs one seed twice and compares the
  per-step decision traces byte for byte (balance, version, durable count, a
  rolling FNV-1a digest of every record written, relay nudges, applied-id
  count, minted-id count). It is load-bearing: replacing the injected id
  generator with `time.Now().UnixNano()` leaves the invariant test **green**
  — the invariants really do still hold — and turns this one red at trace
  line 15. Remove the log digest from the trace and the same nondeterminism
  passes again, which is why that field is in there.

  The injectability this depends on is enforced, not asserted:
  `internal/architecture/boundaries_test.go`'s
  `TestCoreWallClock_TimeNowBannedExceptAllowlist` and
  `TestCoreRandomness_MathRandBannedExceptAllowlist`, both with **empty**
  allowlists, are the fitness functions standing behind "the core reads no
  ambient clock or randomness". This test is what would notice anything they
  do not cover — including nondeterminism introduced by the harness itself,
  which is exactly what the mutation above is.
- **Its own adequacy.** The run asserts floors on what the schedule actually
  did (deposits, admitted withdrawals, rejections, duplicates, faults,
  restarts, minted ids, distinct balances) and logs every counter, so a
  schedule that drifts into "500 deposits" fails instead of passing
  conservation vacuously. That check has already earned its place: the first
  generator hoped for insufficient-balance rejections rather than scheduling
  them, and on seed 42 produced 2 — the floor caught it, and the deliberate
  overdraft draw exists because of it.

## What stage 1 deliberately does NOT cover

**There is no simulated network, no simulated disk, and no simulated
scheduler. Stage 2 does not exist** — not stubbed, not half-wired, not behind
a flag. This harness is single-process and single-goroutine; it does not
drive a process boundary, so it cannot reorder, delay, partition or duplicate
anything at the transport or storage layer. Concurrency and partial failure
across processes are what deterministic simulation is *for*, and this is the
stage before that one.

Saying it this plainly is load-bearing. "We have deterministic simulation" is
exactly the sentence a stage-1 harness makes people say, and believing it is
how a team stops looking for the class of bug it does not yet cover.

Also out of scope on purpose: amount-shape edges (malformed decimals,
precision, overflow). This harness varies the **schedule**; the parser is
`internal/domain`'s fuzz and property territory (`FuzzParseAmount`,
`TestPropertyLedgerConservation_RandomEventSequences`), which explores that
space properly instead of sampling it badly.

Concurrency inside the single process is covered elsewhere too, and better:
`internal/app/ledger_test.go`'s
`TestLedger_CriticalSection_SecondCommandCannotDecideMidCommit` parks a
command inside `Append` deterministically, which is a real gate for a real
defect. This harness does not duplicate it.

## Why this dimension is advisory

Dimension 27 is **advisory** in the standard: no probe row demands that a
repo ship a `verification/simulation/` package, and no required check fails
for its absence. A gate would be the vacuous form. Requiring the dimension
buys a *directory* in every repo the day it lands — directories are cheap to
produce and impossible to falsify from outside — while the thing worth having
is a harness someone has actually pointed at their own system. Simulation
earns a gate the way every other lane in this repo earned one: **after it has
caught something**, with the seed that caught it recorded, at which point the
gate protects a proven mechanism instead of mandating a hopeful one.

Advisory as a *dimension* does not make this file's fixed-seed run optional.
With `SIM_SEED` unset, the schedule is a pure function of `defaultSeed`, so
the test is exactly as deterministic as any other in the module and it runs
in the ordinary `go test ./...` lane. A red here is a reproducible defect,
not a flake. What stays out of the blocking lane is the **random-seed
sweep** (`SIM_SEED=$RANDOM make sim`): its red is a finding to minimize into
`regressions/`, never a reason to stop a merge on a schedule nobody has seen
before.

## When a sweep goes red

1. Record the seed. It is in the failure message and in the reproduce line
   the harness prints.
2. Re-run `SIM_SEED=<seed> make sim` and confirm it is red again. If it is
   not, the defect is not in the schedule — it is nondeterminism in the code
   under test, which is a bigger finding, not a smaller one. (Expect
   `TestSimulation_SeedReproduces` to have caught it first; if it did not,
   the trace is missing a field that the divergence flows through, and
   widening the trace is part of the fix.)
3. Minimize it into a fixture under `regressions/` (see that directory's
   README) so the failure becomes a permanent, fast, deterministic test that
   does not depend on this harness at all.
4. Only then fix the code, and prove the fix with both the fixture and the
   seed.

## Provenance

`sim_test.go` carries `provenance: derived`: the invariants it asserts are
the ratified ones (`verification/ratified/invariants_test.go`), but the
schedule that exercises them is generated here and carries no ratification
package of its own. This directory is **not** part of the trusted set —
unlike `verification/ratified/`, it is agent-writable.
