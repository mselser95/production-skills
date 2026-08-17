# SLO — PROPOSED, not ratified

**Status: PROPOSED.** The SLIs below are all measurable today (their
metrics exist and are scraped); the OBJECTIVE VALUES have not been through
a human ratification review. Per the framework's own rule, inventing an
agreed number here would be exactly the escape hatch it forbids — so this
document states what CAN be measured and proposes numbers a real service
born from this template should replace with its own ratified values before
this file's status changes to RATIFIED.

## SLI: units-conservation correctness

- **Measured by:** `svc_units_conserved_violations_total` (must be 0,
  always — this is not a percentage-based SLO, any nonzero value is a
  page, see `docs/RUNBOOK.md`).
- **Proposed objective:** 0 violations, 100% of the time. Not negotiable
  for a ledger — recorded here rather than omitted so the "propose a
  number" step is not silently skipped for the one SLI that has no
  meaningful percentage form.

## SLI: readiness availability

- **Measured by:** the fraction of `/readyz` scrapes returning 200 over a
  rolling window (a standard uptime-style SLI derivable from any scrape
  history of `svc_eventlog_writable` and the readiness gate's own
  `no_recent_invariant_violation` component — no dedicated metric ships
  for the composite yet; a real deployment should add one before
  ratifying an objective against it).
- **Proposed objective:** 99.9% over 30 days (unratified placeholder).

## SLI: outbox delivery latency

- **Measured by:** not currently emitted as a histogram/summary metric —
  `internal/adapter/out/store.Outbox` tracks attempts per entry
  (`Entry.Attempts`) but does not export delivery latency. A real
  deployment wiring a live `Sink` (replacing the scaffold's `LogSink`)
  should add this before proposing an objective.
- **Proposed objective:** none yet — the SLI itself needs a metric first.

## Rollback

- **Mechanism:** artifact re-pin (redeploy the previous image digest).
  No progressive-delivery automation is wired in this scaffold's
  `.github/workflows/` (a real deployment pipeline is out of this
  template's scope — see the root README's "what this template does NOT
  ship" section).
