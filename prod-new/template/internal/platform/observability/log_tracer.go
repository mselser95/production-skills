package observability

import (
	"context"
	"log/slog"
	"sort"
	"time"
)

// New builds the Tracer selected by mode: "log" wires the structured-log
// adapter (NewLog); anything else ("off", "", or unrecognized) wires
// NewNoop(). This is the composition-root helper cmd/<SERVICE> calls once at
// boot with its validated config.Config.Tracing value -- config.Load
// already rejects any string other than "off"/""/"log" as a boot error, so
// this constructor treats an unrecognized value the same as "off" rather
// than panicking: a tracing default must never be able to crash a boot.
func New(mode string, logger *slog.Logger) Tracer {
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

func (t *logTracer) StartSpan(ctx context.Context, name string, attrs map[string]string) (context.Context, Span) {
	cp := make(map[string]string, len(attrs))
	for k, v := range attrs {
		cp[k] = v
	}
	return ctx, &logSpan{tracer: t, ctx: ctx, name: name, attrs: cp, start: time.Now()}
}

type logSpan struct {
	tracer *logTracer
	// ctx is the context StartSpan was called with, carried to End so the
	// emitted line can be joined to whatever span context the caller was
	// already inside. Holding a context in a struct is the exception Go's
	// own guidance allows for exactly this shape: End() takes no arguments
	// (it is called from a defer), so the only alternative is to drop the
	// context -- which is the defect this file was changed to fix.
	ctx   context.Context
	name  string
	attrs map[string]string
	start time.Time
	err   error
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

	args := make([]any, 0, 4+2*len(keys))
	args = append(args, "span", s.name, "duration_ms", time.Since(s.start).Milliseconds())
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
