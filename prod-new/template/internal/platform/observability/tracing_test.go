package observability

import (
	"context"
	"errors"
	"log/slog"
	"strings"
	"sync"
	"testing"
)

// provenance: derived
// verifies: tracing port (noop default is inert)
func TestNoop_StartSpanAndEndNeverPanicAndDoNothingObservable(t *testing.T) {
	tr := NewNoop()
	ctx, span := tr.StartSpan(context.Background(), "x.y", map[string]string{"a": "b"})
	if ctx == nil {
		t.Fatal("StartSpan returned a nil context")
	}
	span.RecordError(errors.New("boom"))
	span.End()
}

// provenance: derived
// verifies: tracing port (mode selection) -- the exporting mode lives in
// otlp_tracer_test.go, which needs an endpoint and a shutdown.
func TestNewTracer_SelectsBackendByMode(t *testing.T) {
	for _, mode := range []string{TracingOff, "", "bogus"} {
		tr, shutdown, err := NewTracer(context.Background(), TracerOptions{Mode: mode})
		if err != nil {
			t.Fatalf("NewTracer(%q) errored: %v", mode, err)
		}
		if _, ok := tr.(noopTracer); !ok {
			t.Fatalf("NewTracer(%q) did not return the noop tracer, got %T", mode, tr)
		}
		if err := shutdown(context.Background()); err != nil {
			t.Fatalf("NewTracer(%q) shutdown errored: %v", mode, err)
		}
	}
	tr, shutdown, err := NewTracer(context.Background(), TracerOptions{Mode: TracingLog})
	if err != nil {
		t.Fatalf("NewTracer(log) errored: %v", err)
	}
	if _, ok := tr.(*logTracer); !ok {
		t.Fatalf("NewTracer(log) did not return the log tracer, got %T", tr)
	}
	if err := shutdown(context.Background()); err != nil {
		t.Fatalf("NewTracer(log) shutdown errored: %v", err)
	}
}

// provenance: derived
// verifies: tracing port (log adapter emits one structured line per span,
// records errors)
func TestLogTracer_EmitsOneLinePerSpan(t *testing.T) {
	var buf recordingHandler
	logger := slog.New(&buf)
	tr := NewLog(logger)

	_, span := tr.StartSpan(context.Background(), "svc.deposit", map[string]string{"event_id": "e1"})
	span.End()
	if n := buf.snapshot().count; n != 1 {
		t.Fatalf("record count = %d, want 1", n)
	}

	_, span2 := tr.StartSpan(context.Background(), "svc.withdraw", nil)
	span2.RecordError(errors.New("insufficient balance"))
	span2.End()
	if n := buf.snapshot().count; n != 2 {
		t.Fatalf("record count = %d, want 2", n)
	}
	if !buf.snapshot().sawError {
		t.Fatal("span with a recorded error did not emit at Error level")
	}
}

// provenance: derived
// verifies: tracing port (RecordError(nil) is a documented no-op)
func TestLogSpan_RecordErrorNilIsANoOp(t *testing.T) {
	var buf recordingHandler
	tr := NewLog(slog.New(&buf))
	_, span := tr.StartSpan(context.Background(), "svc.deposit", nil)
	span.RecordError(nil)
	span.End()
	if buf.snapshot().sawError {
		t.Fatal("RecordError(nil) caused an Error-level emission")
	}
}

// provenance: derived
// verifies: operational determinism (WithBaseAttrs merges identity into
// every span; per-span attrs win on collision; noop tracer is unchanged)
func TestWithBaseAttrs_MergesAndPrefersPerSpanOnCollision(t *testing.T) {
	rec := NewRecording()
	tr := WithBaseAttrs(rec, map[string]string{"revision": "abc123", "env": "base"})
	_, span := tr.StartSpan(context.Background(), "svc.deposit", map[string]string{"env": "call-site"})
	span.End()

	spans := rec.Named("svc.deposit")
	if len(spans) != 1 {
		t.Fatalf("got %d recorded spans, want 1", len(spans))
	}
	if spans[0].Attrs["revision"] != "abc123" {
		t.Fatalf("attrs = %v, want revision=abc123 merged in", spans[0].Attrs)
	}
	if spans[0].Attrs["env"] != "call-site" {
		t.Fatalf("attrs[env] = %q, want the call-site value to win over the base value", spans[0].Attrs["env"])
	}

	// noop tracer + empty base are both no-ops for WithBaseAttrs.
	if got := WithBaseAttrs(NewNoop(), map[string]string{"a": "b"}); got != NewNoop() {
		// NewNoop() returns a value type each time; compare by asserting it
		// is still the noop implementation rather than pointer equality.
		if _, ok := got.(noopTracer); !ok {
			t.Fatal("WithBaseAttrs wrapped the noop tracer instead of returning it unchanged")
		}
	}
	if got := WithBaseAttrs(rec, nil); got != Tracer(rec) {
		t.Fatal("WithBaseAttrs(tr, nil) did not return tr unchanged")
	}
}

// recordingHandler is a minimal slog.Handler test double.
//
// MUTEX-GUARDED, and not out of habit: otlp_tracer_test.go installs one of
// these as the PROCESS-GLOBAL OTel error sink, where it is reachable from SDK
// export goroutines that outlive the test that created them. Counting without
// a lock there is a data race waiting for the scheduler to notice, and the
// kind that only appears under a different -count or a busier machine.
type recordingHandler struct {
	mu       sync.Mutex
	count    int
	sawError bool
	// lastLevel and lastMsg exist because asserting ARRIVAL is not asserting
	// the signal: a mutation from WarnContext to DebugContext kept every
	// count-only assertion green while making the line invisible in
	// production, where the JSON lane is floored at LOG_LEVEL.
	lastLevel slog.Level
	lastMsg   string
}

func (h *recordingHandler) Enabled(context.Context, slog.Level) bool { return true }
func (h *recordingHandler) Handle(_ context.Context, r slog.Record) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.count++
	h.lastLevel = r.Level
	h.lastMsg = r.Message
	if r.Level == slog.LevelError {
		h.sawError = true
	}
	return nil
}

// snapshot returns a lock-free copy of what the handler has seen, so callers
// read a consistent view without reaching into the guarded fields.
func (h *recordingHandler) snapshot() struct {
	count     int
	sawError  bool
	lastLevel slog.Level
	lastMsg   string
} {
	h.mu.Lock()
	defer h.mu.Unlock()
	return struct {
		count     int
		sawError  bool
		lastLevel slog.Level
		lastMsg   string
	}{h.count, h.sawError, h.lastLevel, h.lastMsg}
}

func (h *recordingHandler) WithAttrs(attrs []slog.Attr) slog.Handler { return h }
func (h *recordingHandler) WithGroup(name string) slog.Handler       { return h }

// provenance: derived
// verifies: tracing port (log adapter) -- a span started with a nil context
// still emits at End instead of panicking.
//
// The nil guard exists because logSpan now CARRIES the context from
// StartSpan to End so the emitted line can be joined to its span. That
// turned a parameter the adapter used to ignore into one it dereferences,
// which is exactly the kind of change that converts a harmless nil into a
// panic inside a deferred End() -- the worst place to find one, because it
// fires during the failure it was supposed to be describing.
func TestLogTracer_NilContextStillEmitsAtEnd(t *testing.T) {
	var buf strings.Builder
	tr := NewLog(slog.New(slog.NewJSONHandler(&buf, nil)))

	var nilCtx context.Context
	_, span := tr.StartSpan(nilCtx, "svc.nil_ctx", map[string]string{"k": "v"})
	span.End()

	if !strings.Contains(buf.String(), "svc.nil_ctx") {
		t.Fatalf("span line was not emitted for a nil-context span: %q", buf.String())
	}
}
