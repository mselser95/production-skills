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
