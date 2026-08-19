package observability

import (
	"bytes"
	"context"
	"encoding/json"
	"log/slog"
	"strings"
	"sync"
	"testing"
	"time"

	otellog "go.opentelemetry.io/otel/log"
	sdklog "go.opentelemetry.io/otel/sdk/log"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
)

// recordingProcessor is an sdklog.Processor that keeps every record it is
// given. It is the whole reason NewOTLPLane takes its downstream processor
// as a parameter: without it, "DEBUG never goes on the wire" could only be
// asserted by reading minsev's source, which proves what the library says it
// does and nothing about how this repo wired it.
type recordingProcessor struct {
	mu      sync.Mutex
	records []sdklog.Record
}

func (p *recordingProcessor) OnEmit(_ context.Context, record *sdklog.Record) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.records = append(p.records, record.Clone())
	return nil
}

// Enabled returns true unconditionally: this processor filters nothing, so
// every drop observed in a test is attributable to the minsev floor and not
// to the recorder.
func (p *recordingProcessor) Enabled(context.Context, sdklog.EnabledParameters) bool { return true }
func (p *recordingProcessor) Shutdown(context.Context) error                         { return nil }
func (p *recordingProcessor) ForceFlush(context.Context) error                       { return nil }

func (p *recordingProcessor) snapshot() []sdklog.Record {
	p.mu.Lock()
	defer p.mu.Unlock()
	out := make([]sdklog.Record, len(p.records))
	copy(out, p.records)
	return out
}

// sampledContext returns a context inside a real, recorded, sampled span,
// plus that span's trace and span ids as strings.
func sampledContext(t *testing.T) (context.Context, string, string) {
	t.Helper()
	provider := sdktrace.NewTracerProvider(sdktrace.WithSampler(sdktrace.AlwaysSample()))
	t.Cleanup(func() { _ = provider.Shutdown(context.Background()) })
	ctx, span := provider.Tracer("test").Start(context.Background(), "unit-of-work")
	t.Cleanup(func() { span.End() })
	sc := span.SpanContext()
	return ctx, sc.TraceID().String(), sc.SpanID().String()
}

// provenance: derived
// verifies: observability contract (logs correlate) -- THE claim. A
// *Context call inside a span carries that span's real trace id; the plain
// variant, at the same call site, in the same span, carries nothing.
//
// This is the test that makes `context: all` in .golangci.yml a rule with
// teeth rather than a style preference: it demonstrates the exact failure
// the lint rule prevents, and it fails if traceHandler is removed from
// NewLogger.
func TestLogger_ContextVariantCarriesTheTraceID_PlainVariantDropsIt(t *testing.T) {
	ctx, traceID, spanID := sampledContext(t)

	var buf bytes.Buffer
	logger, shutdown, err := NewLogger(context.Background(), &buf, LogOptions{Level: slog.LevelInfo})
	if err != nil {
		t.Fatalf("NewLogger: %v", err)
	}
	t.Cleanup(func() { _ = shutdown(context.Background()) })

	logger.InfoContext(ctx, "correlated")
	// The plain variant is the NEGATIVE CONTROL of this test, so the lint
	// rule that bans it everywhere else must be suspended for exactly this
	// line. Without the control the test would assert only that the good
	// path works, which is the half of the claim that was never in doubt.
	logger.Info("uncorrelated") //nolint:sloglint // deliberate: this is the defect being demonstrated

	lines := strings.Split(strings.TrimSpace(buf.String()), "\n")
	if len(lines) != 2 {
		t.Fatalf("expected 2 log lines, got %d: %q", len(lines), buf.String())
	}

	var correlated, plain map[string]any
	if err := json.Unmarshal([]byte(lines[0]), &correlated); err != nil {
		t.Fatalf("line 1 is not JSON (%v): %q", err, lines[0])
	}
	if err := json.Unmarshal([]byte(lines[1]), &plain); err != nil {
		t.Fatalf("line 2 is not JSON (%v): %q", err, lines[1])
	}

	if correlated["trace_id"] != traceID {
		t.Fatalf("InfoContext line trace_id = %v, want %s", correlated["trace_id"], traceID)
	}
	if correlated["span_id"] != spanID {
		t.Fatalf("InfoContext line span_id = %v, want %s", correlated["span_id"], spanID)
	}
	if _, ok := plain["trace_id"]; ok {
		t.Fatalf("Info (plain) line carries a trace_id -- the two variants are indistinguishable, "+
			"so the lint rule guards nothing: %q", lines[1])
	}
}

// provenance: derived
// verifies: observability contract (structured handler INSTALLED) -- the
// stdout lane is JSON with typed fields, not slog's default key=value text.
func TestNewLogger_StdoutLaneIsParseableJSONWithTypedFields(t *testing.T) {
	var buf bytes.Buffer
	logger, shutdown, err := NewLogger(context.Background(), &buf, LogOptions{Level: slog.LevelInfo})
	if err != nil {
		t.Fatalf("NewLogger: %v", err)
	}
	t.Cleanup(func() { _ = shutdown(context.Background()) })

	logger.InfoContext(context.Background(), "svc: recovered state", "events_replayed", 42, "from_snapshot", true)

	var got map[string]any
	if err := json.Unmarshal(buf.Bytes(), &got); err != nil {
		t.Fatalf("log line is not JSON (%v): %q", err, buf.String())
	}
	if got["msg"] != "svc: recovered state" {
		t.Fatalf("msg = %v", got["msg"])
	}
	// A number, not the string "42": the whole point of a structured
	// handler is that a log store can range-query this field.
	if n, ok := got["events_replayed"].(float64); !ok || n != 42 {
		t.Fatalf("events_replayed = %#v, want the number 42", got["events_replayed"])
	}
	if b, ok := got["from_snapshot"].(bool); !ok || !b {
		t.Fatalf("from_snapshot = %#v, want the boolean true", got["from_snapshot"])
	}
}

// provenance: derived
// verifies: observability contract (log level is a real floor)
func TestNewLogger_LevelFloorsTheStdoutLane(t *testing.T) {
	var buf bytes.Buffer
	logger, shutdown, err := NewLogger(context.Background(), &buf, LogOptions{Level: slog.LevelWarn})
	if err != nil {
		t.Fatalf("NewLogger: %v", err)
	}
	t.Cleanup(func() { _ = shutdown(context.Background()) })

	logger.InfoContext(context.Background(), "below the floor")
	logger.WarnContext(context.Background(), "at the floor")

	if strings.Contains(buf.String(), "below the floor") {
		t.Fatalf("INFO line survived a WARN floor: %q", buf.String())
	}
	if !strings.Contains(buf.String(), "at the floor") {
		t.Fatalf("WARN line was dropped at a WARN floor: %q", buf.String())
	}
}

// provenance: derived
// verifies: observability contract -- Export=off builds NO second lane.
//
// A bridge pointed at a no-op provider would convert and allocate for every
// record and then discard it. That is invisible in behaviour and visible
// only in a profile, which is how it survives review.
func TestNewLogger_ExportOff_BuildsNoSecondLane(t *testing.T) {
	logger, shutdown, err := NewLogger(context.Background(), &bytes.Buffer{}, LogOptions{Export: LogExportOff})
	if err != nil {
		t.Fatalf("NewLogger: %v", err)
	}
	t.Cleanup(func() { _ = shutdown(context.Background()) })

	if _, isMulti := logger.Handler().(*slog.MultiHandler); isMulti {
		t.Fatal("Export=off produced a MultiHandler -- something is being fanned out to a lane that cannot deliver")
	}
	if _, isTraced := logger.Handler().(traceHandler); !isTraced {
		t.Fatalf("Export=off handler is %T, want the trace-stamping stdout handler", logger.Handler())
	}
}

// provenance: derived
// verifies: observability contract (OTLP lane is floored at INFO) -- DEBUG
// never reaches the downstream processor even when the stdout lane is
// running at DEBUG, which is the configuration an operator reaches for
// during an incident.
func TestOTLPLane_FloorsDebugEvenWhenTheProcessLevelIsDebug(t *testing.T) {
	recorder := &recordingProcessor{}
	bridge, shutdown := NewOTLPLane(recorder, LogOptions{ServiceName: "svc", ServiceVersion: "test"})
	t.Cleanup(func() { _ = shutdown(context.Background()) })

	var buf bytes.Buffer
	stdout := traceHandler{next: slog.NewJSONHandler(&buf, &slog.HandlerOptions{Level: slog.LevelDebug})}
	logger := slog.New(slog.NewMultiHandler(stdout, bridge))

	logger.DebugContext(context.Background(), "debug line")
	logger.InfoContext(context.Background(), "info line")

	// The stdout lane sees both: turning the level down must still show the
	// operator what they asked for.
	if !strings.Contains(buf.String(), "debug line") || !strings.Contains(buf.String(), "info line") {
		t.Fatalf("stdout lane at DEBUG did not carry both lines: %q", buf.String())
	}

	got := recorder.snapshot()
	for _, record := range got {
		if record.Severity() <= otellog.SeverityDebug4 {
			t.Fatalf("a DEBUG record reached the exporter: %q at severity %v", record.Body().AsString(), record.Severity())
		}
	}
	if len(got) != 1 {
		t.Fatalf("exporter saw %d record(s), want exactly the INFO one", len(got))
	}
	if body := got[0].Body().AsString(); body != "info line" {
		t.Fatalf("exported record body = %q, want %q", body, "info line")
	}
}

// provenance: derived
// verifies: observability contract (logs correlate) on the EXPORTED lane --
// the OTel bridge sets TraceID/SpanID on the record from the call's context,
// so the same *Context requirement holds there.
func TestOTLPLane_ContextVariantSetsTheRecordTraceID(t *testing.T) {
	ctx, traceID, spanID := sampledContext(t)

	recorder := &recordingProcessor{}
	bridge, shutdown := NewOTLPLane(recorder, LogOptions{ServiceName: "svc", ServiceVersion: "test"})
	t.Cleanup(func() { _ = shutdown(context.Background()) })
	logger := slog.New(bridge)

	logger.InfoContext(ctx, "correlated")
	logger.Info("uncorrelated") //nolint:sloglint // deliberate: the negative control, as above

	got := recorder.snapshot()
	if len(got) != 2 {
		t.Fatalf("exporter saw %d record(s), want 2", len(got))
	}
	if got[0].TraceID().String() != traceID || got[0].SpanID().String() != spanID {
		t.Fatalf("InfoContext record = trace %s span %s, want trace %s span %s",
			got[0].TraceID(), got[0].SpanID(), traceID, spanID)
	}
	if got[1].TraceID().IsValid() {
		t.Fatalf("the plain Info record carries a valid trace id (%s) -- the variants are indistinguishable",
			got[1].TraceID())
	}
}

// provenance: derived
// verifies: observability contract (the boot path is structured too) -- the
// one line that says why the process refused to start must be parseable.
func TestNewBootstrapLogger_EmitsJSONAtInfo(t *testing.T) {
	var buf bytes.Buffer
	logger := NewBootstrapLogger(&buf)

	logger.DebugContext(context.Background(), "not this one")
	logger.ErrorContext(context.Background(), "svc: fatal", "error", "boom")

	var got map[string]any
	if err := json.Unmarshal(bytes.TrimSpace(buf.Bytes()), &got); err != nil {
		t.Fatalf("bootstrap line is not JSON (%v): %q", err, buf.String())
	}
	if got["msg"] != "svc: fatal" || got["error"] != "boom" || got["level"] != "ERROR" {
		t.Fatalf("bootstrap line = %#v", got)
	}
}

// provenance: derived
// verifies: observability contract -- traceHandler delegates WithAttrs and
// WithGroup instead of silently dropping the wrapper, so a logger built with
// logger.With(...) keeps correlating.
func TestTraceHandler_SurvivesWithAttrsAndWithGroup(t *testing.T) {
	ctx, traceID, _ := sampledContext(t)

	var buf bytes.Buffer
	logger, shutdown, err := NewLogger(context.Background(), &buf, LogOptions{Level: slog.LevelInfo})
	if err != nil {
		t.Fatalf("NewLogger: %v", err)
	}
	t.Cleanup(func() { _ = shutdown(context.Background()) })

	logger.With("pod_id", "pod-1").InfoContext(ctx, "with attrs")
	if !strings.Contains(buf.String(), traceID) {
		t.Fatalf("logger.With(...) dropped the trace stamp: %q", buf.String())
	}
	if !strings.Contains(buf.String(), `"pod_id":"pod-1"`) {
		t.Fatalf("logger.With(...) dropped its own attribute: %q", buf.String())
	}

	// WithGroup: the stamp survives, nested inside the group -- the KNOWN
	// LIMIT documented on traceHandler, asserted here so it is a stated
	// property rather than a surprise on someone's dashboard.
	buf.Reset()
	logger.WithGroup("req").InfoContext(ctx, "with group")
	var got map[string]any
	if err := json.Unmarshal(bytes.TrimSpace(buf.Bytes()), &got); err != nil {
		t.Fatalf("grouped line is not JSON (%v): %q", err, buf.String())
	}
	if _, topLevel := got["trace_id"]; topLevel {
		t.Fatal("trace_id appeared at the top level of a grouped record -- update the KNOWN LIMIT note on traceHandler")
	}
	group, ok := got["req"].(map[string]any)
	if !ok || group["trace_id"] != traceID {
		t.Fatalf("grouped record did not carry the trace stamp under its group: %#v", got)
	}
}

// provenance: derived
// verifies: observability contract -- Export=otlp really does build the
// second lane, and the fan-out keeps the stdout lane intact.
//
// This exercises the REAL exporter constructor (otlploghttp), not a fake:
// the branch that ships in production is the branch under test. It needs no
// collector because nothing is emitted -- an exporter that dialled at
// construction would be a boot-time dependency on the collector being up,
// which is itself worth knowing does not happen.
func TestNewLogger_ExportOTLP_FansOutWithoutLosingTheStdoutLane(t *testing.T) {
	var buf bytes.Buffer
	logger, shutdown, err := NewLogger(context.Background(), &buf, LogOptions{
		Level:          slog.LevelInfo,
		Export:         LogExportOTLP,
		ServiceName:    "svc",
		ServiceVersion: "test",
	})
	if err != nil {
		t.Fatalf("NewLogger(Export=otlp): %v", err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = shutdown(ctx)
	})

	if _, isMulti := logger.Handler().(*slog.MultiHandler); !isMulti {
		t.Fatalf("Export=otlp handler is %T, want a MultiHandler fanning out to both lanes", logger.Handler())
	}

	ctx, traceID, _ := sampledContext(t)
	logger.InfoContext(ctx, "still on stdout")
	if !strings.Contains(buf.String(), "still on stdout") {
		t.Fatalf("enabling the OTLP lane silenced the stdout lane: %q", buf.String())
	}
	if !strings.Contains(buf.String(), traceID) {
		t.Fatalf("enabling the OTLP lane dropped the stdout lane's trace stamp: %q", buf.String())
	}
}
