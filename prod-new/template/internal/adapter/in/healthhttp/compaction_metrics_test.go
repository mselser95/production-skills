package healthhttp

import (
	"io"
	"net/http"
	"strconv"
	"strings"
	"testing"
	"time"
)

// fakeOutbox satisfies OutboxHealth with fixed readings, so the exposition can
// be driven without a real durable outbox.
type fakeOutbox struct {
	pending        int
	oldest         time.Duration
	unknownAge     int
	deadLettered   int
	compactRuns    int
	compactDropped int
	compactBytes   int64
}

func (f fakeOutbox) PendingStats() (int, time.Duration, int) {
	return f.pending, f.oldest, f.unknownAge
}
func (f fakeOutbox) DeadLetterCount() int { return f.deadLettered }
func (f fakeOutbox) CompactionStats() (int, int, int64) {
	return f.compactRuns, f.compactDropped, f.compactBytes
}

func scrapeBody(t *testing.T, srv *Server) string {
	t.Helper()
	base := serveTest(t, srv)
	resp, err := http.Get(base + "/metrics")
	if err != nil {
		t.Fatalf("get /metrics: %v", err)
	}
	defer func() { _ = resp.Body.Close() }()
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read body: %v", err)
	}
	return string(raw)
}

// seriesValue reads one unlabelled series' sample value out of a scrape.
func seriesValue(t *testing.T, body, name string) (float64, bool) {
	t.Helper()
	for _, line := range strings.Split(body, "\n") {
		if strings.HasPrefix(line, "#") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) != 2 || fields[0] != name {
			continue
		}
		v, err := strconv.ParseFloat(fields[1], 64)
		if err != nil {
			t.Fatalf("series %q has unparseable value %q", name, fields[1])
		}
		return v, true
	}
	return 0, false
}

// provenance: derived
// verifies: what compaction reclaimed REACHES THE SCRAPE. The mechanism
// counted its own work and emitted none of it in the first shape of this
// change, which is the exact defect the standard keeps finding: a bound that
// exists, works, and cannot be seen -- so "compaction reclaimed nothing" and
// "compaction never ran" look identical from outside the process, and they
// have opposite consequences.
func TestCompactionStats_ReachTheScrape(t *testing.T) {
	srv := New(nil, Options{Outbox: fakeOutbox{
		compactRuns: 4, compactDropped: 20000, compactBytes: 4886670,
	}})
	body := scrapeBody(t, srv)

	for name, want := range map[string]float64{
		"svc_outbox_compactions_total":                4,
		"svc_outbox_compacted_entries_total":          20000,
		"svc_outbox_compaction_reclaimed_bytes_total": 4886670,
	} {
		got, ok := seriesValue(t, body, name)
		if !ok {
			t.Errorf("series %q is absent from the scrape -- compaction is unobservable", name)
			continue
		}
		if got != want {
			t.Errorf("%s = %v, want %v", name, got, want)
		}
	}
}

// provenance: derived
// verifies: the three readings are NOT conflated. "It ran 7 times and reclaimed
// nothing" is the diagnosis docs/RUNBOOK.md § "Outbox compaction has stopped
// reclaiming" is built on, and it is unreachable if runs are inferred from
// bytes or entries from runs.
func TestCompactionStats_AreNotConflated(t *testing.T) {
	srv := New(nil, Options{Outbox: fakeOutbox{compactRuns: 7, compactDropped: 0, compactBytes: 0}})
	body := scrapeBody(t, srv)

	if v, ok := seriesValue(t, body, "svc_outbox_compactions_total"); !ok || v != 7 {
		t.Errorf("compactions_total = %v (present=%t), want 7", v, ok)
	}
	if v, ok := seriesValue(t, body, "svc_outbox_compacted_entries_total"); !ok || v != 0 {
		t.Errorf("compacted_entries_total = %v (present=%t), want 0", v, ok)
	}
	if v, ok := seriesValue(t, body, "svc_outbox_compaction_reclaimed_bytes_total"); !ok || v != 0 {
		t.Errorf("reclaimed_bytes_total = %v (present=%t), want 0", v, ok)
	}
}

// provenance: derived
// verifies: a Server with NO outbox still serves the series, at zero. The
// alternative -- omitting them -- would make the contract test's both-direction
// check pass only for a fully-wired server, and a missing series reads to a
// dashboard as "no data", which is not the same claim as zero.
func TestCompactionStats_AbsentOutboxReportsZeroesRatherThanNothing(t *testing.T) {
	body := scrapeBody(t, New(nil, Options{}))
	for _, name := range []string{
		"svc_outbox_compactions_total",
		"svc_outbox_compacted_entries_total",
		"svc_outbox_compaction_reclaimed_bytes_total",
	} {
		v, ok := seriesValue(t, body, name)
		if !ok {
			t.Errorf("series %q missing entirely with no outbox wired", name)
		}
		if v != 0 {
			t.Errorf("%s = %v with no outbox wired, want 0", name, v)
		}
	}
}

// provenance: regression
// verifies: svc_otlp_export_failures_total carries the INJECTED count, not a
// hardcoded zero.
//
// The metrics-contract test only proves the series NAME appears in the scrape
// and in the manifest, in both directions. That is exactly satisfied by a
// series wired to nothing: substituting `_ = s.opts.OTLPExportFailures` for
// the call left the whole healthhttp package green while the series read 0
// forever -- the same "instrumented but never injected" shape that made
// Outbox.Reconcile decoration, reproduced in the freshly added counter.
//
// A non-zero, non-round value on purpose: a series accidentally wired to some
// other zero-ish reading would still pass a `== 0` check.
func TestOTLPExportFailures_ReachTheScrape(t *testing.T) {
	srv := New(nil, Options{OTLPExportFailures: func() int64 { return 37 }})
	got, ok := seriesValue(t, scrapeBody(t, srv), "svc_otlp_export_failures_total")
	if !ok {
		t.Fatal("svc_otlp_export_failures_total is absent from the scrape -- " +
			"dropped telemetry is then visible only to whoever already suspects it")
	}
	if got != 37 {
		t.Fatalf("svc_otlp_export_failures_total = %v, want 37 -- the series is not reading the "+
			"injected counter, so it will report 0 while every export fails", got)
	}

	// Nil is legal (a pod with no exporter wired) and must report 0 rather
	// than panicking a scrape.
	if v, ok := seriesValue(t, scrapeBody(t, New(nil, Options{})), "svc_otlp_export_failures_total"); !ok || v != 0 {
		t.Fatalf("with no counter injected the series = %v (present=%t), want 0", v, ok)
	}
}
