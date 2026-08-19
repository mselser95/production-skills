package observability

import (
	"context"
	"io"
	"log/slog"

	"go.opentelemetry.io/contrib/bridges/otelslog"
	"go.opentelemetry.io/contrib/processors/minsev"
	"go.opentelemetry.io/otel/exporters/otlp/otlplog/otlploghttp"
	sdklog "go.opentelemetry.io/otel/sdk/log"
	"go.opentelemetry.io/otel/sdk/resource"
	semconv "go.opentelemetry.io/otel/semconv/v1.43.0"
	"go.opentelemetry.io/otel/trace"
)

// Log export modes, mirroring config.Config.LogExport (env LOG_EXPORT).
const (
	// LogExportOff writes JSON to the process's own stream and nothing
	// else. The scaffold's default: a service with no collector in front
	// of it must not pay for an exporter that has nowhere to send.
	LogExportOff = "off"
	// LogExportOTLP additionally fans every record out to the
	// OpenTelemetry log bridge, which ships it over OTLP/HTTP to the
	// endpoint OTEL_EXPORTER_OTLP_ENDPOINT names.
	LogExportOTLP = "otlp"
)

// otlpMinSeverity is the floor for the OTLP lane: DEBUG never goes on the
// wire, whatever LOG_LEVEL is set to.
//
// This is deliberately NOT the same knob as the process log level. Turning
// LOG_LEVEL=debug during an incident is a local, reversible act; it must not
// silently multiply the volume every collector, ingester and log store
// downstream has to absorb. An OTLP log record was measured at ~834 B on the
// wire, so a debug-chatty loop is a bandwidth and a bill, not just noise --
// and the operator who flipped the level to see one thing is the last person
// positioned to notice. The stdout lane still shows every DEBUG line; only
// the exported one is floored.
const otlpMinSeverity = minsev.SeverityInfo

// LogOptions is everything NewLogger needs. Every field is supplied by the
// composition root from validated config -- this package reads no
// environment of its own, so a test can construct any combination without
// mutating process state.
type LogOptions struct {
	// Level is the floor for the human/stdout lane.
	Level slog.Level
	// Export selects the OTLP lane: LogExportOff or LogExportOTLP.
	Export string
	// ServiceName and ServiceVersion identify this process in the exported
	// resource, and ServiceName doubles as the instrumentation scope name.
	ServiceName    string
	ServiceVersion string
}

// NewLogger builds the process logger and returns it with the shutdown
// function the composition root must defer.
//
// # Why this exists at all
//
// `slog.Default()` is a TEXT handler writing to stderr. A service can log
// diligently for months through it and emit nothing a log store can parse
// into fields: the keys survive as `key=value` text, the values lose their
// types, and every query is a regex over a message. This constructor is the
// difference between "we have logs" and "we can ask our logs a question".
//
// # The two lanes, and why they are separate
//
// The stdout lane is JSON so `kubectl logs`, a Loki pipeline and a human
// with `jq` all read the same bytes. The OTLP lane is the collector's copy.
// They are fanned out with the stdlib slog.NewMultiHandler rather than by
// making one lane a filter of the other, because they have genuinely
// different floors: the stdout lane shows whatever LOG_LEVEL asks for, and
// the OTLP lane is floored at otlpMinSeverity no matter what.
//
// When Export is off there is NO fan-out. A bridge pointed at a no-op
// LoggerProvider would convert and allocate for every record and then drop
// it -- an instrumented mechanism nobody wired, which is exactly the defect
// this repo's probes hunt one level up (a tracer constructed and discarded).
//
// # Beta, and said out loud
//
// OpenTelemetry Go's LOGS signal is Beta (go.opentelemetry.io/otel/log is
// still v0.x) while traces and metrics are Stable v1.x. That means the
// bridge and exporter APIs above may still break compatibly-versioned
// upgrades. It is a considered trade -- the alternative is a bespoke
// exporter -- but it is not the same maturity as the tracing wiring beside
// it, and a reader of this file should not have to discover that from a
// build failure.
func NewLogger(ctx context.Context, w io.Writer, opts LogOptions) (*slog.Logger, func(context.Context) error, error) {
	stdout := traceHandler{next: slog.NewJSONHandler(w, &slog.HandlerOptions{Level: opts.Level})}

	if opts.Export != LogExportOTLP {
		return slog.New(stdout), noopShutdown, nil
	}

	// KNOWN GAP, measured rather than assumed: otlploghttp.New reads
	// OTEL_EXPORTER_OTLP_ENDPOINT itself, and an unparseable value does NOT
	// come back as this error -- the SDK logs "invalid
	// OTEL_EXPORTER_OTLP_ENDPOINT value" through its own error handler and
	// falls back to localhost:4318. So a typo'd collector endpoint boots
	// clean and exports into the void, which is the opposite of how this
	// repo treats TRACING and LOG_LEVEL (both are boot errors on a typo).
	// Closing it properly means re-implementing the OTLP env precedence
	// rules (OTEL_EXPORTER_OTLP_LOGS_ENDPOINT overrides
	// OTEL_EXPORTER_OTLP_ENDPOINT, with per-signal path defaults), and a
	// half-right reimplementation would be worse than the honest note. If
	// this service starts depending on the exported lane, validate the
	// endpoint in config.Load, where every other fail-closed check lives.
	exporter, err := otlploghttp.New(ctx)
	if err != nil {
		return nil, nil, err
	}
	bridge, shutdown := NewOTLPLane(sdklog.NewBatchProcessor(exporter), opts)
	return slog.New(slog.NewMultiHandler(stdout, bridge)), shutdown, nil
}

// NewOTLPLane builds the exported half of NewLogger from an already-built
// SDK log processor, returning the bridge handler and the provider's
// Shutdown.
//
// It is exported and takes the DOWNSTREAM processor as a parameter for one
// reason: the severity floor is a claim ("DEBUG never goes on the wire")
// that has to be provable without a collector. A test hands this a recording
// processor and reads what actually reached it. Building the exporter inside
// NewLogger and asserting the floor by reading minsev's source would be the
// decorative form of the same check.
func NewOTLPLane(downstream sdklog.Processor, opts LogOptions) (slog.Handler, func(context.Context) error) {
	provider := sdklog.NewLoggerProvider(
		sdklog.WithResource(resource.NewWithAttributes(
			semconv.SchemaURL,
			semconv.ServiceName(opts.ServiceName),
			semconv.ServiceVersion(opts.ServiceVersion),
		)),
		// minsev wraps the processor rather than the handler on purpose: it
		// implements the SDK's Enabled hook too, so a record below the floor
		// is refused BEFORE the bridge converts it into a log.Record. A
		// handler-level filter would still pay the conversion.
		sdklog.WithProcessor(minsev.NewLogProcessor(downstream, otlpMinSeverity)),
	)
	return otelslog.NewHandler(opts.ServiceName, otelslog.WithLoggerProvider(provider)), provider.Shutdown
}

func noopShutdown(context.Context) error { return nil }

// NewBootstrapLogger returns the logger used before (or instead of) the
// configured one: JSON, INFO, on w.
//
// It exists because the configured logger's LEVEL comes from config, and
// config loading can itself fail. Without this, the one error that says why
// the process refused to start would be the one error emitted through the
// unstructured default handler -- unparseable exactly when it matters most.
func NewBootstrapLogger(w io.Writer) *slog.Logger {
	return slog.New(traceHandler{next: slog.NewJSONHandler(w, &slog.HandlerOptions{Level: slog.LevelInfo})})
}

// traceHandler stamps trace_id/span_id from the RECORD'S CONTEXT onto every
// line the stdout lane emits.
//
// This is the half of log/span correlation that people assume slog does and
// it does not. slog.NewJSONHandler knows nothing about OpenTelemetry: it
// receives the context and ignores it. So `logger.InfoContext(ctx, ...)`
// inside a span produces, from a bare JSON handler, a line that is
// indistinguishable from one logged outside any span. Correlation would then
// exist only in the OTLP lane -- which is OFF in this scaffold's default
// configuration, making "our logs correlate" true only for deployments that
// run a collector. That is the hollow kind of pass this repo exists to
// refuse.
//
// Note the *Context requirement this creates, which is the whole point: a
// plain `logger.Info()` hands slog a context.Background() and this handler
// finds no span in it. The stamp appears if and only if the call site passed
// the real context, which is why .golangci.yml runs sloglint with
// `context: all`.
//
// KNOWN LIMIT: if a caller opens a group (Logger.WithGroup), the stamp lands
// INSIDE that group rather than at the top level of the record. Nothing in
// this scaffold opens a group, and slog gives a handler no way to write
// above an open group. A service that starts grouping should query
// `.<group>.trace_id` or stop grouping the span-scoped lines; it should not
// discover the nesting from a dashboard that silently matches nothing.
type traceHandler struct{ next slog.Handler }

func (h traceHandler) Enabled(ctx context.Context, level slog.Level) bool {
	return h.next.Enabled(ctx, level)
}

func (h traceHandler) Handle(ctx context.Context, record slog.Record) error {
	if sc := trace.SpanContextFromContext(ctx); sc.IsValid() {
		// snake_case, like every other key, metric name, metric label and
		// span attribute in this repo. Loki and Prometheus silently rewrite
		// anything outside [a-zA-Z0-9_:] in a LABEL name to `_`, so a
		// `trace-id` key promoted to a label becomes `trace_id` at query
		// time with no error and no result -- one convention everywhere is
		// the only way nobody has to remember which surface they are on.
		record.AddAttrs(
			slog.String("trace_id", sc.TraceID().String()),
			slog.String("span_id", sc.SpanID().String()),
		)
	}
	return h.next.Handle(ctx, record)
}

func (h traceHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	return traceHandler{next: h.next.WithAttrs(attrs)}
}

func (h traceHandler) WithGroup(name string) slog.Handler {
	return traceHandler{next: h.next.WithGroup(name)}
}
