# Handoff: the relay landed; three files I do not own still describe the outbox

Written by the track that added `internal/platform/relay` (commit `0b1cf2c`).
Everything below is measured, not inferred. Nothing here is blocking that
commit; all of it is work for the owners of the named files.

## 1. To the owner of `production.yaml` and `observability/emitted-metrics.yaml`

**Measured defect.** `cmd/<SERVICE>` still calls `rebuildOutboxFromLog` at boot,
which journals one entry per deliverable event into `store.Outbox`. Nothing
drains it — `Reconcile` has no caller in production code (already recorded in
`registries/contract-debt.yaml:57`). Probe, three consecutive boots over a
5-event log:

```
boot 1: rebuilt 5 entries, PENDING=5
boot 2: rebuilt 0 entries, PENDING=5
boot 3: rebuilt 0 entries, PENDING=5
```

It does not grow per boot — identity-keyed journaling is idempotent, which is
correct — but it holds one entry per event **forever**. So
`svc_outbox_pending_entries` is permanently non-zero and
`svc_outbox_oldest_pending_age_seconds` grows without bound. Any alert on
either fires permanently. `emitted-metrics.yaml:79` explicitly directs
operators to alert on the age series, so this is a live false alarm the
template ships with.

**Why it is now vestigial.** The outbox existed to close the window between
committing an event and recording its effect. The relay closes that window by
construction: the log IS the outbox, there is no second store, and the only
extra durable fact is a position. `Relay.Lag` reports what the pending count
used to approximate, measured against the one store that exists.

**The change, if you agree.** Retire the outbox from the composition root and:

- `production.yaml:118` `durable_outbox: store.OpenDurable` → the relay
- `production.yaml:121` `outbox_reconcile: store.(*Outbox).Reconcile` → drop
- `production.yaml:261` `effect_journal_outbox` → repoint at
  `TestEndToEnd_EventLogIsTheOutbox` (`./internal/adapter/out/store`)
- `effect_journal_atomic` → repoint at the restart half of that same test; the
  original window it guarded no longer exists to be atomic about
- `emitted-metrics.yaml:73,82,95,106` — the four `svc_outbox_*` series →
  replace with a relay lag series and a relay-stalled signal. The metrics
  contract test diffs code against manifest in BOTH directions, so the code
  change and the manifest change must land together or the gate reds.
- `registries/contract-debt.yaml:57` — the never-called-`Reconcile` debt is
  discharged by deletion rather than by wiring it.

I did not make these edits: `9a724a8` and `fa23e72` show another track already
working this area, and colliding would be worse than the false alarm.

## 2. To the owner of `_shared/mechanism-derivation.md` — originator vs consumer

The derivation currently reads as a choice between shapes. In practice a
service is frequently **both at once**, and that case has a specific structure
worth stating outright, because getting it wrong is not recoverable later:

- **One log, not two.** State depends on the interleaving of *all* facts the
  service folded. Two logs cannot reproduce that order without recording the
  merge order somewhere — which is one log with extra steps. Provenance goes on
  the record (`Origin: raised | ingested`), not in the choice of file.
- **An ingested fact carries TWO positions, and they mean different things.**
  The *foreign* position is the deduplication and gap-detection key: a hole in
  it is a fact not yet received, which cannot be invented, only waited for. The
  *local* position is the order this log observed things and never has holes;
  it is what the relay checkpoints and what a downstream consumer orders on.
  Collapsing them loses exactly one meaning each way.
- **Derived facts must be RAISED, not re-derived.** Anything a service concludes
  from accumulated state belongs in the log as its own event. This keeps the
  relay's mapper a 1:1 translation. The alternative — re-folding in the mapper —
  is the bug documented in `mapper-refold-silently-drops-events`: an admitted
  withdrawal re-folded against a fresh state reads as *rejected*, so it is
  silently never published.

Suggested derivation output: not "originator OR consumer" but three
independent questions — *does it raise facts?*, *does it ingest ordered facts
from an upstream authority?*, *does it publish outward?* — since a service can
answer yes to all three and the mechanisms compose.

## 3. What I did not verify

- A zero-width `Unlock()/Lock()` immediately after `domain.Apply` stays GREEN
  under the critical-section gate. The realistic break (lock dropped around the
  append) goes red. I could not construct a deterministic probe for the
  zero-width case without a test hook in production code, and it is
  unobservable from outside the ledger in that construction.
- Gap-safety of `eventlog.ReadAfter` is argued from the storage choice (single
  writer, append-only file) and asserted for that implementation only. Any
  replacement store — Postgres in particular, which hands out sequence numbers
  before commit — owes its own proof before being wired to a relay.
- The relay's behaviour under a real broker. `LogPublisher` confirms
  synchronously, which is the contract, but no network publisher was exercised.
