# Runbook

## Units-conservation violation (`svc_units_conserved_violations_total > 0`)

**Severity:** page, T0-class (`tier-policy.yaml`: `invariant_flake_rule:
incident` for any data-correctness invariant, even on a T1 service).

1. Confirm it is real: `curl http://<pod>:<health-port>/metrics | grep
   svc_units_conserved_violations_total`. A nonzero value here means
   `internal/app.Ledger`'s runtime check
   (`domain.ConservationHolds`) disagreed with what `domain.Apply` actually
   produced for a real command.
2. Do NOT restart the pod as a first response — restarting loses the
   in-memory detail of which command triggered it (the durable event log
   itself is unaffected; recovery via `internal/platform/eventlog.Rebuild`
   will reproduce the SAME balance, corrupted or not, since `Rebuild` folds
   the same `domain.Apply` the running process used).
3. Pull the structured logs around the violation (if `TRACING=log`, the
   `svc.deposit`/`svc.withdraw` span for the offending command carries
   `event_type` and a `RecordError` entry if the command itself also
   failed).
4. This is never a data-correctness question to "fix in prod" — treat it
   as a code defect in `internal/domain`'s arithmetic
   (`internal/domain/money.go` / `internal/domain/ledger.go`) until proven
   otherwise, and escalate per `prod-incident`.

## Duplicate-event violation (`svc_duplicate_event_violations_total > 0`)

**Severity:** page. Same investigation shape as above — the specific
suspect is `domain.Apply`'s idempotency guard
(`if state.Applied[event.ID] {`).

## Event log not writable (`svc_eventlog_writable == 0`, `/readyz` 503)

1. Check disk space / permissions on the pod's `EVENTLOG_PATH` volume.
2. The pod is correctly reporting NOT READY — the load balancer already
   pulled it; no additional mitigation is needed beyond fixing the
   underlying disk/permission issue and letting `/readyz` recover on its
   own once `internal/platform/eventlog.Log.Writable()` returns true
   again.

## Outbox entries stuck in `intent`/`failed`

The outbox (`internal/adapter/out/store`) has no background sweep wired
into `cmd/<SERVICE>` yet in this scaffold — `Outbox.Reconcile(ctx)` exists and is
tested (`internal/adapter/out/store/outbox_test.go`,
`conformance_kit_test.go`'s `crash_between_decision_and_effect` scenario)
but nothing calls it on a timer. A real deployment should wire a periodic
`Reconcile` call (or a dedicated sweep endpoint) before depending on outbox
recovery in production; until then, a stuck entry is only resumed by a
manual `Reconcile` call from an operator context (e.g. a one-off debug
binary or REPL that constructs the same `Outbox` against the running pod's
in-memory state — not currently exposed over HTTP by this scaffold).

## Rolling back a bad deploy

`docs/SLO.md`'s rollback lever is `artifact_repin`: redeploy the previous
image digest. No feature flags currently gate the units-ledger capability
(see `registries/flags.yaml` — empty).
