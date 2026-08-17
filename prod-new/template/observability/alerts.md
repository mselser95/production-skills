# Alerts

Every alert here cites a series declared in `emitted-metrics.yaml`
(checked mechanically: nothing here should reference a metric name that
file doesn't declare — this is a template's starting set, not a ratified
SLO; see `docs/SLO.md`).

## `SvcUnitsConservedViolation` (page)

```
svc_units_conserved_violations_total > 0
```

**Meaning:** the ratified invariant `units_conserved` has been violated at
runtime — `internal/app.Ledger`'s `checkInvariants` detected a command whose
resulting balance did not match `domain.ConservationHolds`'s independently
computed expectation. This must never happen; it means either
`internal/domain`'s arithmetic is wrong or something bypassed
`domain.Apply`.

**This is a T0-class page, not a warning.** Per `tier-policy.yaml`'s
`invariant_flake_rule: incident`, a nondeterministic reproduction of this
alert is an incident to investigate, never a metric to quarantine.

**First response:** read `docs/RUNBOOK.md`'s "Units-conservation
violation" section.

## `SvcDuplicateEventViolation` (page)

```
svc_duplicate_event_violations_total > 0
```

**Meaning:** the ratified invariant `duplicate_event_single_effect` has been
violated — an event ID already marked `Applied` nonetheless changed the
ledger's balance on a re-submission. `domain.Apply`'s idempotency guard is
the only thing that should ever prevent this; its failure means the guard
itself broke.

## `SvcReadyzSelfAuditViolation` (warn)

```
svc_readyz_stale_never_ready_audits_total > 0
```

**Meaning:** the readiness gate's own self-consistency audit
(`internal/adapter/in/healthhttp/invariant_counters.go`) found `/readyz`'s
`ready` verdict disagreeing with its own component gates. Since the real
formula (`ready := logOK && violationOK`) cannot produce this on its own,
a nonzero value here means the AUDIT WIRING itself is broken (a code
change bypassed the shared formula), not that readiness itself is lying —
but it is a signal that the readiness contract can no longer be trusted
and warrants investigation before the next deploy.

## `SvcEventLogNotWritable` (page)

```
svc_eventlog_writable == 0
```

**Meaning:** the durable event log is not open for writing — every command
will fail at the journal-append step (`internal/app.Ledger.process`'s
`csReceived -> csLogged` transition). The pod is correctly reporting
NOT READY via this same gate; this alert exists so the page fires even if
nothing is actively polling `/readyz` at the moment.
