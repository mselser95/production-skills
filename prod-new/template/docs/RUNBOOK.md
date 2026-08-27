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

`cmd/<SERVICE>` runs `reconcileLoop`, which drives `Outbox.Reconcile(ctx)`
on two triggers: a **10s ticker** (`outboxReconcileInterval`) and a
**wake-up** signalled once at boot, after the outbox has replayed its journal
and the event log has been re-derived into it. So an entry left behind by a
sink outage is retried without anyone doing anything, and one left behind by
a crash is retried in milliseconds rather than after a full interval.

**What that means at 3am.** A single stuck entry is expected to clear itself.
An entry stuck for MINUTES means the sink is still refusing it, not that
nothing is trying: look for `svc: outbox reconciled` lines with a non-zero
`still_down`, which is the loop reporting that it attempted and failed.
`svc_outbox_oldest_pending_age_seconds` climbing steadily is the same
statement as a gauge.

1. Confirm the loop is alive: `svc: outbox reconciled` should appear whenever
   anything is pending. Total silence with `svc_outbox_pending_entries > 0`
   means the goroutine is gone — that is a code defect, and
   `production.yaml`'s `driven: outbox_reconcile` row (`main.reconcileLoop`)
   is what fails the build when it is.
2. Investigate the SINK, since the loop has already ruled itself out.
3. `svc_outbox_dead_lettered_total > 0` is a different and worse problem: the
   bounds evicted an entry, and `Reconcile` deliberately ignores dead-lettered
   entries so an eviction is not undone by the very loop that could not
   deliver it. Those need `Outbox.Requeue` — an explicit operator decision,
   not currently exposed over HTTP by this scaffold.

## Outbox compaction has stopped reclaiming

**Signal:** `svc_outbox_compactions_total` climbing across restarts while
`svc_outbox_compaction_reclaimed_bytes_total` stays flat, and the outbox log
growing on disk.

Compaction runs **on boot only** (`main.compactOutboxLog`), after
`OpenDurable` has replayed the log and after `rebuildOutboxFromLog` has walked
the event log. It folds away entries that are terminal (`delivered`,
`dead_lettered`) **and** no longer re-derivable from the event log; anything
else it must keep, because this log doubles as the **delivery watermark** —
dropping a delivered entry the event log can still re-derive would make the
next boot read that identity as unknown, re-journal it, and republish the
effect on every boot.

Boot-only is not a scheduling convenience: the retain set is precisely what
the event-log walk just reported, and computing it against a log that has
moved is how a compaction starts republishing history.

So "reclaimed nothing" has several very different causes, and the entries
series is what separates them:

| compactions | entries dropped | bytes reclaimed | reading |
|---|---|---|---|
| climbing | 0 | 0 | nothing terminal to fold — normal for a young or quiet service |
| climbing | >0 | ~0 | it is folding entries but they are tiny; watch the file, not the counter |
| climbing | 0 | 0, file growing | **the liability**: the live set is not shrinking. Look for entries that never reach a terminal state — a sink down for longer than `MaxPendingAge`, or dead letters nobody has requeued — and for an event log that stopped snapshotting, since the replay tail is the other half of the bound |
| flat at 0 | — | — | compaction is not running. Check the boot log for `svc: compacted the outbox log` and whether `OpenDurable` was reached at all |

**What to do:** this is not a page. It is a slow leak whose cost is boot time,
and boot time is what an operator feels during an incident, not before one.
Check `svc_outbox_pending_entries` and `svc_outbox_dead_lettered_total` first —
a growing log with a growing pending set is a delivery problem wearing a
storage problem's clothes.

**If the boot log says compaction FAILED** (`svc: outbox log compaction failed,
the log keeps growing`) the reclaim is the only thing that was lost: the
pre-compaction log is complete and authoritative, because the rewrite is
write-new → fsync → rename → fsync the directory → reopen, and a failure
anywhere before the rename leaves the original file untouched. A stray
`<outbox>.jsonl.compact` beside the log is a leftover of that path and is safe
to delete.

## Rolling back a bad deploy

`docs/SLO.md`'s rollback lever is `artifact_repin`: redeploy the previous
image digest. No feature flags currently gate the units-ledger capability
(see `registries/flags.yaml` — empty).

## Reading the logs, and joining them to a trace

**Where they go.** Every line is JSON on stdout, from a handler built in
`internal/platform/observability.NewLogger` and wired at the composition
root. Nothing in this service writes through `slog.Default()` — that is a
text handler on stderr, and `.golangci.yml`'s `sloglint: no-global` makes
adding one a lint failure rather than a discovery six months later.

**How to join a log line to its span.** Every line logged from inside a span
carries `trace_id` and `span_id` at the top level. Grepping one trace is
`jq 'select(.trace_id=="<id>")'`; in Loki, `| json | trace_id="<id>"`.

If a line you expected to see has NO `trace_id`, the call site used
`logger.Info(…)` instead of `logger.InfoContext(ctx, …)` — the plain
variants drop the context, which is what `sloglint: context: all` exists to
prevent. That is a code defect, not a configuration problem; do not go
looking at the collector.

If NO line in the whole process carries a `trace_id`, check `TRACING` first:
`off` (a valid setting) wires the no-op tracer, which starts no span, so
there is nothing for a line to be stamped with. `/healthz` reports the live
value.

**A `trace_id` on a log line does NOT mean the trace is in your backend.**
Under `TRACING=log` the span is a log line and nothing else: the id is real,
it joins lines within this process, and it will 404 in Tempo/Jaeger because
no exporter was ever wired. Only `TRACING=otlp` ships spans anywhere.
`/healthz` reports `config.tracing` and `config.tracing_endpoint` together for
exactly this question — "is this pod exporting, and to where?" is a lookup:
`curl -s :8081/healthz | jq .config`.

**Following one command past the durable log.** The command and the
publication it causes are ONE trace, and they are emitted seconds or a
restart apart:

    jq 'select(.trace_id=="<id>")' — the `svc.deposit` span line and the
    `relay delivery` line for the same fact both match.

What joins them is not a context — a context does not survive a process. It
is the `traceparent` field the event log persists with the record
(`jq 'select(.id=="<event id>") | .traceparent' events.jsonl`) and the
`traceparent` key in the published envelope's metadata. If a delivery line
has no `trace_id`, look at the record on disk: a fact committed before this
field existed, or committed outside any span (a background job, a
`TRACING=off` deployment), has no parent to restore, and publishing it as a
new root is correct. A record that HAS a traceparent while its delivery line
does not is a code defect in the mapper or the publisher — see
`internal/platform/observability/propagation.go`.

**The four levers.**

| Env | Default | Effect |
| --- | --- | --- |
| `LOG_LEVEL` | `info` | Floor for the stdout lane: `debug`, `info`, `warn`, `error`. A value outside that set is a BOOT ERROR, not a silent fallback. |
| `LOG_EXPORT` | `off` | `otlp` additionally ships records to `OTEL_EXPORTER_OTLP_ENDPOINT` (a full URL). |
| `TRACING` | `off` | `log` = one structured line per span, no collector. `otlp` = export spans over OTLP/HTTP. Anything else is a BOOT ERROR. |
| `TRACING_ENDPOINT` | — | `host:port`, **no scheme** (`tempo:4318`). REQUIRED under `TRACING=otlp`; a missing or malformed value is a BOOT ERROR. |

All four are surfaced live under `/healthz`'s `config` object (it is
`config.Identity` marshalled whole, so a field added there appears here
automatically — `TestHealthz_SurfacesEveryConfigIdentityField` fails if one
does not). `curl -s :8081/healthz | jq .config` answers "there are no DEBUG
lines" and "are we exporting traces" without guessing what the pod was
started with.

Until this change the endpoint printed four literals and read `config.Identity`
only for its digest, so none of these fields had ever actually been served —
the paragraph you are reading was false for as long as it existed. That is
the failure mode worth remembering here: a runbook step nobody executes reads
exactly like one that works.

**Sampling is 100% and `OTEL_TRACES_SAMPLER` does nothing.** The tracer
declares `ParentBased(AlwaysSample)` explicitly, which makes the SDK's own
`OTEL_TRACES_SAMPLER` / `OTEL_TRACES_SAMPLER_ARG` variables inert. That is on
purpose: an env var this repo never validates and never surfaces on `/healthz`
must not be able to take a service to zero traces. A service with real volume
owes a validated config knob beside `TRACING_ENDPOINT`, not a reach for the
OTel variable. An upstream `sampled=0` decision IS respected — including one
restored from a durable `traceparent`.

**The two endpoints want OPPOSITE shapes, and this bites everyone once.**
`OTEL_EXPORTER_OTLP_ENDPOINT` (logs) is a full URL, path included.
`TRACING_ENDPOINT` (traces) is a bare `host:port` — `otlptracehttp` adds the
scheme and the `/v1/traces` path itself, so `http://tempo:4318` there makes
the *whole string* the hostname. That exact value is refused by name at boot
(`observability.validateTraceEndpoint`).

**Traces are best-effort; their CONFIG is not.** A collector that is down at
boot, or that dies at 03:00, cannot fail this service: nothing dials at
construction, spans go to a bounded in-memory queue, `End()` is a queue
append, and a full queue DROPS spans. Measured on this scaffold against a
listener that ACCEPTS connections and never answers — which is what a
degraded collector actually looks like, and far harsher than a closed port —
1000 spans complete in **1.3 ms** total. With the batching removed the same
1000 spans did not finish in two minutes.

So export failures are WARN lines
(`observability: OTLP export failed (service unaffected)`) plus the
`svc_otlp_export_failures_total` counter, and never an outage. A *malformed*
endpoint, by contrast, refuses the boot — because that failure is otherwise
completely silent, and the pod would look healthy while every span went
nowhere.

**The export-failure signal spans every OTLP signal, not just traces.**
`otel.SetErrorHandler` is process-global and the OpenTelemetry *log* SDK
reports through it too, so under `LOG_EXPORT=otlp` a log-collector outage
also increments `svc_otlp_export_failures_total` and emits the same WARN. The
`error` field carries the failing URL (`/v1/traces` vs `/v1/logs`) — read it
before deciding which collector to chase. Those lines go to **stderr as JSON,
deliberately not through the process logger**: routing them through a logger
that is itself exporting makes a collector outage self-sustaining, which was
measured here at ~1 line/second forever from a single seed log line.

**What no check here can catch.** An endpoint with the right shape and the
wrong host. `tempo:4318` when the collector is `tempo-gateway:4318` passes
validation, boots clean, and exports into the void with only WARN lines to
show for it. The only proof is querying a trace back from the backend after
a deploy.

**`LOG_LEVEL=debug` does not put debug traffic on the wire.** The OTLP lane
is floored at INFO by `minsev` (`observability.otlpMinSeverity`) regardless
of `LOG_LEVEL`, so turning the level down during an incident costs local
volume only. You will see the DEBUG lines in `kubectl logs`; the collector
will not.

**Known gap.** An unparseable `OTEL_EXPORTER_OTLP_ENDPOINT` is NOT a boot
error: the OTel SDK logs `invalid OTEL_EXPORTER_OTLP_ENDPOINT value` through
its own error handler and falls back to `localhost:4318`, so a typo exports
into the void while the pod looks healthy. If exported logs go missing,
check that line in the pod's own stderr before suspecting the collector.
See the note on `otlploghttp.New` in
`internal/platform/observability/logging.go`.

## Telemetry is being dropped (`svc_otlp_export_failures_total` climbing)

**Series:** `svc_otlp_export_failures_total`. **Severity: warn, never a page.**
The service is unaffected — nothing about telemetry is on the request path,
and a full span queue drops spans rather than blocking a command. What is
affected is your ability to see anything, which is why it must not be
ignored either: a dashboard showing nothing wrong may be showing nothing at
all.

**First: which signal?** The counter is shared. `otel.SetErrorHandler` is
process-global and the OpenTelemetry log SDK reports through it, so under
`LOG_EXPORT=otlp` this climbs for log-export failures too. The WARN line
beside it carries the URL:

    kubectl logs <pod> | jq 'select(.msg | test("OTLP export failed")) | .error'

`.../v1/traces` is the trace exporter (`TRACING_ENDPOINT`); `.../v1/logs` is
the log exporter (`OTEL_EXPORTER_OTLP_ENDPOINT`). They are configured
separately and want opposite endpoint shapes — see "The four levers" above.

**Then, in order:**

1. `curl -s :8081/healthz | jq .config` — confirm `tracing` and
   `tracing_endpoint` are what this deployment intends. A syntactically valid
   endpoint pointing at the wrong host boots clean and fails every export;
   that is the one case no boot-time check can catch.
2. Reach the collector from the pod's own network position, not from your
   laptop. `TRACING_ENDPOINT` is resolved and dialled by this pod.
3. If the collector is genuinely down, there is nothing to do here: the
   counter stops climbing when it returns, spans emitted in the meantime are
   gone, and no restart is required or helpful.

**Do not** restart the service to "reset" the counter. It is monotonic by
design — a counter that drops is one every `rate()` misreads as a restart —
and restarting discards the queued spans that a recovering collector would
otherwise have received.

## The service says it is ready and clients say it is not (`SvcGrayFailure`)

**Severity: page.** This is the gray-failure condition (Huang et al., "Gray
Failure: The Achilles' Heel of Cloud-Scale Systems", HotOS 2017): the pod's
own health signals are green and an external vantage says it is unusable.
Traffic is still being routed to it, because every mechanism that would take
it out of rotation — the readiness gate, the restart policy — reads the view
that says everything is fine.

**Do not start by looking for the bug. Start by deciding which view is
wrong,** because the two answers send you to opposite places and the alert
deliberately does not tell you which it is. That is not an omission: the
whole content of the signal is that the two disagree.

1. **Take the pod out of rotation first.** Whatever the cause, it is serving
   the bad path to real traffic while this is being diagnosed, and nothing
   in the service will do that on its own — that is the definition of the
   condition. Cordon it, scale the replica, or drop it from the backend pool
   by hand.
2. **Reproduce the client view from the client's network position**, not
   from your laptop and not with `kubectl exec` into the pod. A request that
   succeeds from inside the pod and fails from outside it localises the
   fault to the path between them (ingress, service mesh sidecar, network
   policy, an LB health check reading a different port), and that path is
   invisible to every signal this service emits.
3. **Read the pod's own view, in full:**

       curl -s :8081/readyz | jq .
       curl -s :8081/healthz | jq '{state, config}'

   `/readyz` gives the gate breakdown (`log_writable`,
   `no_recent_invariant_violation`); `/healthz`'s `state` object gives the
   ledger this process reconstructed. A pod that is READY, has a plausible
   `state.balance`, and still fails from outside is a path problem. A pod
   that is READY with `state.known: false` is a pod that never got a ledger,
   which readiness does not currently gate on — record that as a finding
   rather than as the incident's cause.
4. **Check whether it is fail-SLOW rather than fail-stop.** Gunawi et al.,
   "Fail-Slow at Scale" (FAST 2018), collected 101 incidents of hardware
   that kept working at a fraction of its speed for weeks — the binary
   readiness probe passes throughout, which is exactly how the traffic keeps
   arriving. Compare `svc_outbox_oldest_pending_age_seconds` and the
   command latency on this pod against its peers before concluding the pod
   is healthy; "responding" and "responding usefully" are different
   readings and only one of them is gated.
5. **If the self view turns out to be the wrong one, that is the finding.**
   The repair is not to silence this alert; it is to give the readiness gate
   a component that can see whatever the prober saw, and to file the gap.
   A readiness formula that cannot go false in a condition clients can see
   is the vacuous form of a readiness probe — and per this repo's own rules,
   the finding belongs in `registries/contract-debt.yaml` with an owner and
   an expiry, so it comes back on its own.

**Do not** resolve this by widening the client-side threshold in
`observability/alerts.md` until the divergence stops firing. An alert edited
until it is quiet has been deleted with extra steps, and this is the one
alert in this repo that fires on a condition no other signal here can see.
