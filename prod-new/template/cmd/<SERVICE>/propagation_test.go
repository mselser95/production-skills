package main

import (
	"bytes"
	"context"
	"encoding/json"
	"path/filepath"
	"testing"

	"github.com/<OWNER>/<SERVICE>/internal/adapter/out/store"
	"github.com/<OWNER>/<SERVICE>/internal/app"
	"github.com/<OWNER>/<SERVICE>/internal/domain"
	"github.com/<OWNER>/<SERVICE>/internal/platform/clock"
	"github.com/<OWNER>/<SERVICE>/internal/platform/eventlog"
	"github.com/<OWNER>/<SERVICE>/internal/platform/ids"
	"github.com/<OWNER>/<SERVICE>/internal/platform/observability"
	"github.com/<OWNER>/<SERVICE>/internal/platform/relay"
)

// provenance: regression
// verifies: observability END TO END -- a command and the publication it
// causes land in ONE trace, through the REAL constructors this composition
// root wires, across a durable log and a process restart.
//
// A span is not a trace. Every other tracing test in this module asserts that
// one mechanism is correct in isolation, and a service can pass all of them
// while the backend holds one trace per span: measured, in the service this
// template was extracted from, 3132 spans received and 3132 traces created,
// with a correctly wired tracer, full attribute fidelity, RecordError firing
// on exactly the declared condition, and a green span contract test.
//
// So this test asserts the only thing that distinguishes those two worlds:
// two lines emitted at different times, by different components, on either
// side of a durable boundary, carrying the SAME trace_id. Nothing is stubbed
// -- observability.New builds the tracer, adaptTracer bridges it, app.Ledger
// commits, eventlog persists, relay tails, store.LogPublisher delivers.
//
// The restart is not decoration either: the relay reads a REOPENED log, so
// what carries the trace across the gap is the bytes on disk and nothing else.
func TestTracePropagation_ACommandAndItsPublicationShareOneTrace(t *testing.T) {
	dir := t.TempDir()
	logPath := filepath.Join(dir, "events.jsonl")

	var out bytes.Buffer
	logger := observability.NewBootstrapLogger(&out)

	// -- boot 1: commit a fact under a span ------------------------------
	elog, err := eventlog.Open(logPath)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	// The seam the composition root wires. eventlog does not import
	// observability -- it is storage -- so this test wires it exactly as
	// main() does, which is what makes the wiring visible rather than
	// implicit.
	elog.SetTraceParentSource(observability.TraceParentFromContext)
	ledger := app.NewLedger(domain.NewState(), elog, func() {}, clock.Real{}.Now, ids.Real{}.NewID)
	ledger.SetTracer(adaptTracer(observability.New("log", logger)))
	if _, err := ledger.Deposit(context.Background(), "e1", "10"); err != nil {
		t.Fatalf("Deposit: %v", err)
	}
	if err := elog.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	// -- boot 2: a different process publishes it ------------------------
	reopened, err := eventlog.Open(logPath)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer func() { _ = reopened.Close() }()
	checkpoints, err := relay.OpenCheckpoints(filepath.Join(dir, "checkpoints.json"))
	if err != nil {
		t.Fatalf("OpenCheckpoints: %v", err)
	}
	rel, err := relay.New[eventlog.SeqEvent](
		reopened, checkpoints, store.EnvelopeMapper("units"), store.NewLogPublisher(logger),
		relay.NopLeader(), relay.Options{Name: "integration-events"})
	if err != nil {
		t.Fatalf("relay.New: %v", err)
	}
	if err := rel.RunToEnd(context.Background()); err != nil {
		t.Fatalf("relay drain: %v", err)
	}

	// -- read what an operator would read --------------------------------
	lines := parseJSONLines(t, out.Bytes())
	span := findLine(t, lines, "span", "svc.deposit")
	delivery := findLine(t, lines, "msg", "relay delivery")

	commandTrace, _ := span["trace_id"].(string)
	if commandTrace == "" {
		t.Fatal("the span line carries NO trace_id -- no context in this process ever contained " +
			"a span, so nothing downstream can be attributed to the command")
	}
	deliveryTrace, _ := delivery["trace_id"].(string)
	if deliveryTrace == "" {
		t.Fatalf("the delivery line carries NO trace_id: %v -- the publication is an orphan, "+
			"and the trace of the command stops at the durable log", delivery)
	}
	if deliveryTrace != commandTrace {
		t.Fatalf("the command is in trace %s and its publication is in trace %s -- two traces "+
			"for one causal chain, which is what a backend holding one trace per span looks like",
			commandTrace, deliveryTrace)
	}

	// The publication is attributed to the COMMAND's span, not to some other
	// span that happens to be in the same trace.
	commandSpan, _ := span["span_id"].(string)
	deliverySpan, _ := delivery["span_id"].(string)
	if commandSpan == "" || deliverySpan != commandSpan {
		t.Fatalf("the delivery is attributed to span %q, want the committing span %q",
			deliverySpan, commandSpan)
	}

	// And the envelope on the wire carries the header a consumer in another
	// process reads -- lowercase and verbatim, the one thing an HTTP-shaped
	// carrier would have got wrong invisibly.
	metadata, ok := delivery["metadata"].(map[string]any)
	if !ok {
		t.Fatalf("delivery line has no metadata map: %v", delivery)
	}
	if _, ok := metadata[observability.TraceParentHeader]; !ok {
		t.Fatalf("the published envelope %v carries no %q, so a consumer starts a new trace",
			metadata, observability.TraceParentHeader)
	}
}

func parseJSONLines(t *testing.T, raw []byte) []map[string]any {
	t.Helper()
	var out []map[string]any
	for _, line := range bytes.Split(bytes.TrimSpace(raw), []byte("\n")) {
		if len(line) == 0 {
			continue
		}
		var m map[string]any
		if err := json.Unmarshal(line, &m); err != nil {
			t.Fatalf("log line is not JSON (%v): %s", err, line)
		}
		out = append(out, m)
	}
	return out
}

func findLine(t *testing.T, lines []map[string]any, key, value string) map[string]any {
	t.Helper()
	for _, m := range lines {
		if s, _ := m[key].(string); s == value {
			return m
		}
	}
	t.Fatalf("no log line with %s=%q in %v", key, value, lines)
	return nil
}
