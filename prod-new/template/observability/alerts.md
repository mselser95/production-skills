# Alerts

Every alert here cites a series declared in `emitted-metrics.yaml`
(checked mechanically: nothing here should reference a metric name that
file doesn't declare — this is a template's starting set, not a ratified
SLO; see `docs/SLO.md`).

**With exactly one deliberate exception, and it is deliberate in the strong
sense: the exception cannot be removed without destroying the alert.**
`SvcGrayFailure` below reads one series this service emits and one it
structurally cannot, because the condition it detects is a DISAGREEMENT
between two vantage points and a self-emitted "client view" is not a client
view. That row says so in place, and `emitted-metrics.yaml` must not grow a
declaration for the external half — a series this process could emit is, by
construction, the wrong half of that comparison.

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

## `SvcOTLPExportFailures` (warn)

```
increase(svc_otlp_export_failures_total[15m]) > 0
```

**Meaning:** OTLP exports are failing, so telemetry is being dropped. This
spans EVERY signal: the OpenTelemetry error handler is process-global, so
under `LOG_EXPORT=otlp` a log-collector outage increments this too. The WARN
line that accompanies each failure carries the failing URL, which is what
distinguishes `/v1/traces` from `/v1/logs`.

**Warn, never a page, and that is a decision rather than an omission.**
Nothing about telemetry is on the request path — the exporter never dials at
boot, `Span.End()` is a queue append, and a full queue drops spans — so the
service is genuinely unaffected. Paging on it would train the rotation to
treat a real outage's first symptom as noise.

**But it must not be silent either.** This is the one condition under which
"the dashboards look fine" carries no information, so an alert that nobody is
woken by is still the difference between noticing and not.

**First response:** read `docs/RUNBOOK.md`'s "Telemetry is being dropped"
section.

## `SvcGrayFailure` (page)

```
# self view: this pod reported itself READY for the whole window ...
  min_over_time(svc_eventlog_writable[10m]) == 1
and on(instance)
# ... while an OUT-OF-PROCESS prober found it unusable for the same window.
# `probe_success` is the blackbox exporter's series -- it is NOT declared in
# emitted-metrics.yaml and must never be; see below.
  avg_over_time(probe_success{job="blackbox",service="<SERVICE>"}[10m]) < 0.99
```

**Meaning:** the service is up according to itself and down according to the
people using it. Huang, Guo, Lin, Bolosky, Bansal, Ravindranath, Chen, Zhang,
Kang and others, "Gray Failure: The Achilles' Heel of Cloud-Scale Systems"
(HotOS 2017, DOI 10.1145/3102980.3103005), name this state and make the
observation the whole alert rests on: a gray failure is precisely a
*differential observability* condition. The component's own health check
passes while an application on top of it sees errors, timeouts, or latency
that makes it unusable. The system is not up and it is not down; **it is up
according to itself**, and that is a state a binary readiness probe cannot
express no matter how many signals it collects, because every one of them is
collected from the vantage that is wrong.

**THE DIVERGENCE IS THE DETECTOR, AND NEITHER SIGNAL CARRIES IT.** This is
the part that is easy to get wrong while looking right, so it is worth being
explicit about. Each half of the expression above, alerted on alone, is
already covered elsewhere in this file and in `docs/SLO.md`:
`svc_eventlog_writable == 0` is `SvcEventLogNotWritable`, and a client SLI
below its objective is the readiness-availability SLI missing its target.
Both of those fire on a state the system AGREES it is in. This row fires on
the state where the two views contradict each other, which is the one
condition neither can report by itself — and which is also the condition
under which every other alert in this file is silent by construction, since
each of them reads only the self view.

**Why the client series is not in `emitted-metrics.yaml`, and must not be.**
The whole content of the alert is that the second reading comes from
somewhere the failing process does not control. A series this pod emitted
about its own usability would execute in the same process, on the same host,
over the same devices, and through the same code path whose failure is being
looked for — it would be a third self-report wearing a client's name, and
the alert would go quiet in exactly the failure it exists for. So
`probe_success` here stands for whatever genuinely external vantage a real
deployment has: a blackbox prober, the ingress's own success rate, a
synthetic canary, or a real consumer's error rate. The label selector is a
placeholder; **the requirement is the vantage, not the exporter.**

**A deployment with no external vantage cannot run this alert, and should
say so rather than rewrite it.** The honest response is a
`registries/waivers.yaml` entry with an owner and an expiry, not a version of
this expression whose "client" half is another `svc_*` series. The second one
looks like the alert and detects nothing.

**Vacuous forms**, each of which has been shipped somewhere by someone:

- **A client half sourced from the service itself.** Covered above; it is the
  failure mode this row exists to prevent, so it is first.
- **No declared window, or a window shorter than a scrape interval.** The two
  vantages are sampled by different systems on different schedules, so a
  pointwise comparison alerts on skew — a scrape that landed either side of a
  restart, not a divergence. `min_over_time`/`avg_over_time` over a stated
  window (10m here) is what makes the condition "these disagreed and kept
  disagreeing" rather than "these were read at different moments". The window
  is the declaration: change it deliberately, and change it in `docs/SLO.md`
  at the same time.
- **A client threshold pinned to 0.** `probe_success == 0` is a hard outage,
  which the self view usually notices too. Gray failure lives at the
  partial-degradation end, so the threshold has to sit at the SLO boundary
  (0.99 here, tracking the readiness-availability objective in
  `docs/SLO.md`), not at total failure.
- **A `for:` duration long enough to outlive the incident.** This alert
  already carries its window inside the expression; adding a further multi-
  hour `for:` on top is how a real gray failure gets waited out instead of
  paged on.

**Page, not warn, and here that follows from the mechanism rather than from
severity taste.** A pod reporting itself ready stays in the load-balancer
pool, so a gray failure is not merely undetected — traffic is actively being
routed toward the fault, which is the worst available arrangement. Nothing
recovers this on its own, because every automatic mechanism that would (the
readiness gate, the restart policy) is driven by the view that says
everything is fine.

**First response:** read `docs/RUNBOOK.md`'s "The service says it is ready
and clients say it is not" section.
