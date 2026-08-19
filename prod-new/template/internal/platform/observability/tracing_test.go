package observability

import (
	"context"
	"errors"
	"log/slog"
	"strings"
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
// verifies: tracing port (mode selection)
func TestNew_SelectsBackendByMode(t *testing.T) {
	if _, ok := New("off", nil).(noopTracer); !ok {
		t.Fatal(`New("off", nil) did not return the noop tracer`)
	}
	if _, ok := New("", nil).(noopTracer); !ok {
		t.Fatal(`New("", nil) did not return the noop tracer`)
	}
	if _, ok := New("bogus", nil).(noopTracer); !ok {
		t.Fatal(`New("bogus", nil) did not fall back to the noop tracer`)
	}
	if _, ok := New("log", nil).(*logTracer); !ok {
		t.Fatal(`New("log", nil) did not return the log tracer`)
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
	if buf.count != 1 {
		t.Fatalf("record count = %d, want 1", buf.count)
	}

	_, span2 := tr.StartSpan(context.Background(), "svc.withdraw", nil)
	span2.RecordError(errors.New("insufficient balance"))
	span2.End()
	if buf.count != 2 {
		t.Fatalf("record count = %d, want 2", buf.count)
	}
	if !buf.sawError {
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
	if buf.sawError {
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
type recordingHandler struct {
	count    int
	sawError bool
}

func (h *recordingHandler) Enabled(context.Context, slog.Level) bool { return true }
func (h *recordingHandler) Handle(_ context.Context, r slog.Record) error {
	h.count++
	if r.Level == slog.LevelError {
		h.sawError = true
	}
	return nil
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
