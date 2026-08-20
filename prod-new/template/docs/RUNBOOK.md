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

**The two levers.**

| Env | Default | Effect |
| --- | --- | --- |
| `LOG_LEVEL` | `info` | Floor for the stdout lane: `debug`, `info`, `warn`, `error`. A value outside that set is a BOOT ERROR, not a silent fallback. |
| `LOG_EXPORT` | `off` | `otlp` additionally ships records to `OTEL_EXPORTER_OTLP_ENDPOINT`. |

Both are surfaced live on `/healthz` (`config.Identity`'s `log_level` /
`log_export`), so "there are no DEBUG lines" can be answered without
guessing whether the pod was started with them enabled.

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
