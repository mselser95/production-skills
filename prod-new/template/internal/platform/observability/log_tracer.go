package observability

import (
	"context"
	"crypto/rand"
	"log/slog"
	"sort"
	"time"

	oteltrace "go.opentelemetry.io/otel/trace"
)

// New builds the Tracer selected by mode: "log" wires the structured-log
// adapter (NewLog); anything else ("off", "", or unrecognized) wires
// NewNoop(). This is the composition-root helper cmd/<SERVICE> calls once at
// boot with its validated config.Config.Tracing value -- config.Load
// already rejects any string other than "off"/""/"log" as a boot error, so
// this constructor treats an unrecognized value the same as "off" rather
// than panicking: a tracing default must never be able to crash a boot.
func New(mode string, logger *slog.Logger) Tracer {
	// Installed for EVERY mode, including "off", and BEFORE the switch so no
	// return path can skip it.
	//
	// The propagator is what lets a trace cross a process boundary at all;
	// leaving it to the composition root is how it came to be missing
	// entirely (see propagation.go: 3132 spans, 3132 traces). Installing it
	// under "off" costs nothing -- the noop tracer produces no span context
	// to inject -- and it removes a mode-dependent difference in behaviour
	// that nobody would think to test: a service running TRACING=log with the
	// propagator installed only on some other branch injects nothing, with no
	// error and no clue.
	InstallPropagation()

	if mode == "log" {
		return NewLog(logger)
	}
	return NewNoop()
}

// NewLog returns a Tracer that emits ONE structured slog line per span, at
// End: the span name, its duration, every declared attribute (sorted for a
// deterministic, greppable line), and the recorded error if any. This is
// the exporter-free tracing backend -- it writes through the process logger
// and opens no connection to a collector, so "TRACING=log" is safe in any
// environment. A nil logger falls back to slog.Default().
//
// The span line is emitted with the *Context variants against the context
// StartSpan was given, so a service that later swaps this for a real OTel
// tracer keeps the same joinable line rather than discovering the gap then.
func NewLog(logger *slog.Logger) Tracer {
	if logger == nil {
		logger = slog.Default()
	}
	return &logTracer{logger: logger}
}

type logTracer struct {
	logger *slog.Logger
}

// StartSpan derives a REAL W3C span context and returns it in the context.
//
// This adapter used to return ctx unchanged, and that made every other piece
// of tracing in this scaffold structurally inert rather than merely
// unexercised: nothing in the process ever held a context containing a span,
// so logging.go's traceHandler found no span context to stamp (every line
// carried no trace_id, not thirty-two zeroes -- an absence, which reads as
// "this line was outside a span"), and propagation.go's Inject wrote no
// header on any boundary. Every unit test still passed, because each piece
// was individually correct.
//
// The span context is a CHILD of whatever ctx already carries -- including a
// REMOTE parent restored by ContextWithTraceParent from a durable record --
// and a fresh root only when ctx carries nothing. That single rule is what
// makes a trace span a process boundary and a restart.
func (t *logTracer) StartSpan(ctx context.Context, name string, attrs map[string]string) (context.Context, Span) {
	if ctx == nil {
		ctx = context.Background()
	}
	cp := make(map[string]string, len(attrs))
	for k, v := range attrs {
		cp[k] = v
	}
	parent := oteltrace.SpanContextFromContext(ctx)
	ctx = oteltrace.ContextWithSpanContext(ctx, childSpanContext(parent))
	return ctx, &logSpan{tracer: t, ctx: ctx, parent: parent, name: name, attrs: cp, start: time.Now()}
}

// childSpanContext builds the span context for a span started under parent:
// the parent's trace id (so they are ONE trace) with a fresh span id, or a
// fresh trace id when there is no parent.
//
// Sampled unconditionally. This backend writes through the process logger and
// opens no connection to a collector, so there is no volume to shed and an
// unsampled flag would only tell a downstream service to drop a trace this
// one has already fully recorded.
func childSpanContext(parent oteltrace.SpanContext) oteltrace.SpanContext {
	cfg := oteltrace.SpanContextConfig{
		TraceID:    parent.TraceID(),
		SpanID:     newSpanID(),
		TraceFlags: oteltrace.FlagsSampled,
		TraceState: parent.TraceState(),
	}
	if !cfg.TraceID.IsValid() {
		cfg.TraceID = newTraceID()
	}
	return oteltrace.NewSpanContext(cfg)
}

// newTraceID and newSpanID mint identifiers from crypto/rand.
//
// Deliberately NOT routed through internal/platform/ids, this module's
// injected randomness port, and the exception is worth stating because the
// rule it bends is enforced mechanically elsewhere. That port exists so a
// test can make DOMAIN identity deterministic -- an event id decides
// idempotency, so a random one is a behaviour a test cannot pin. A span id
// decides nothing: it is telemetry, it is never compared, persisted as
// identity, or branched on, and the ids port yields 32 hex characters where
// W3C needs exactly 8 and 16 raw bytes. Every real OTel SDK mints these the
// same way.
//
// crypto/rand.Read cannot fail on any supported platform (Go 1.24+ made it
// infallible and panics internally on a broken OS entropy source), so the
// zero-value retry below is defensive only: an all-zero id is the INVALID
// sentinel in the W3C spec, and emitting one would produce a span the backend
// silently discards.
func newTraceID() oteltrace.TraceID {
	for {
		var id oteltrace.TraceID
		_, _ = rand.Read(id[:])
		if id.IsValid() {
			return id
		}
	}
}

func newSpanID() oteltrace.SpanID {
	for {
		var id oteltrace.SpanID
		_, _ = rand.Read(id[:])
		if id.IsValid() {
			return id
		}
	}
}

type logSpan struct {
	tracer *logTracer
	// ctx is the context StartSpan RETURNED -- the one carrying this span's
	// own span context, not the caller's -- carried to End so the emitted
	// line is stamped with this span's trace_id and span_id rather than its
	// parent's. Holding a context in a struct is the exception Go's own
	// guidance allows for exactly this shape: End() takes no arguments (it is
	// called from a defer), so the only alternative is to drop the context --
	// which is the defect this file was changed to fix.
	ctx context.Context
	// parent is the span context StartSpan found in the caller's context,
	// kept so the emitted line can name it. trace_id and span_id are stamped
	// by logging.go's traceHandler from ctx; parent_span_id is not, and it is
	// the field that makes PARENTING readable in a log-only deployment --
	// without it two lines sharing a trace id say nothing about which caused
	// which.
	parent oteltrace.SpanContext
	name   string
	attrs  map[string]string
	start  time.Time
	err    error
}

func (s *logSpan) RecordError(err error) {
	if err == nil {
		return
	}
	s.err = err
}

func (s *logSpan) End() {
	s.tracer.emit(s)
}

func (t *logTracer) emit(s *logSpan) {
	keys := make([]string, 0, len(s.attrs))
	for k := range s.attrs {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	args := make([]any, 0, 6+2*len(keys))
	args = append(args, "span", s.name, "duration_ms", time.Since(s.start).Milliseconds())
	if s.parent.IsValid() {
		args = append(args, "parent_span_id", s.parent.SpanID().String())
	}
	for _, k := range keys {
		args = append(args, k, s.attrs[k])
	}

	ctx := s.ctx
	if ctx == nil {
		ctx = context.Background()
	}
	if s.err != nil {
		args = append(args, "error", s.err.Error())
		t.logger.ErrorContext(ctx, "span", args...)
		return
	}
	t.logger.InfoContext(ctx, "span", args...)
}
