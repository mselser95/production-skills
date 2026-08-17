# The replay corpus

This directory is this service's **event-sourcing regression capability**.
The ledger's durable state IS an append-only event log
(`internal/platform/eventlog`), so a fixture here is a curated, minimized
event sequence replayed through the REAL production path:

```
domain.Apply (the same function internal/app.Ledger and
internal/platform/eventlog.Rebuild both call)
```

The driver is `internal/domain/replay_corpus_test.go` (`TestReplayCorpus`,
which discovers and runs every fixture below as a subtest).

## The contract

1. **Minimized, not raw.** A fixture is a handful of hand-shaped events,
   never a captured production tape (this template has no production
   history — the first real fixture born from an incident follows the same
   discipline via `prod-incident`).
2. **Invariants, not golden state.** A fixture asserts
   `domain.ConservationHolds` at **every** transition (an independent
   recomputation of what the after-state should be, not a tautological
   re-check of `Apply`'s own output) plus one end-of-replay assertion
   (`fixture.yaml`'s `expect_final_balance`) — never "the balance at step 3
   is exactly X" snapshots that would break on every intended behavior
   change.
3. **Both colors, or it doesn't count.** Every fixture's `fixture.yaml`
   carries a `# counterexample:` block naming the exact code mutation that
   turns it red, and that mutation has been **empirically verified**:
   applied locally, the fixture's subtest run and confirmed red, then
   reverted before commit. See the verification log below.
4. **Schema-version migration duty.** `fixture.yaml`'s `schema_version: 1`
   pins the `events.json` shape `runFixture` parses. A future incompatible
   change to the event schema must bump `schema_version` in the harness AND
   every fixture in one PR.

## Fixture format

```
regressions/<yyyy-mm-dd>-<slug>/
  fixture.yaml    # schema_version, incident, date, summary, minimized_from,
                   # expect_final_balance, and a `# counterexample:` block
  events.json     # []{"id","type","amount","note"}
  invariants.txt  # which invariant(s) this fixture proves non-vacuous
```

No YAML dependency: `fixture.yaml` is read with a tiny hand-rolled scanner
(mirroring `internal/platform/eventlog`'s own "no dependency for a simple
format" discipline) that looks for one `expect_final_balance: "..."` line.

## The corpus

| fixture | primary invariant | source |
|---|---|---|
| `2026-08-17-duplicate-deposit-and-overdraft-guard` | units_conserved + duplicate_event_single_effect | hand-shaped at scaffold time, mirroring `internal/domain/ledger_property_test.go`'s generator |

## Verification log

| fixture | mutation | result |
|---|---|---|
| `2026-08-17-duplicate-deposit-and-overdraft-guard` | `ledger.go`'s `EventWithdrawn` branch: `SubAmounts(state.Balance, event.Amount)` → `SubAmounts(state.Balance, state.Balance)` | RED — `step 1 (ordinary withdrawal, leaves 7): ConservationHolds failed for before={Balance:10.00000000 ...} after={Balance:0.00000000 ...}` |

Verified 2026-08-17: the mutation was applied to a clean worktree, the
fixture's subtest was run in isolation and the failure above was observed
and confirmed to match `fixture.yaml`'s prediction, then the file was
reverted (`diff` against the pre-mutation copy showed no residual change)
before this corpus was committed.

## Running the corpus

```sh
go test ./internal/domain/... -run TestReplayCorpus -v
```

Every fixture directory is discovered automatically; there is no registry
to keep in sync. `TestReplayCorpus` fails if zero fixture directories are
found, so the corpus cannot silently shrink to zero.
