package app

import (
	"context"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"testing"

	"github.com/<OWNER>/<SERVICE>/internal/platform/observability"
)

// provenance: derived
// verifies: observability contract (tier-policy: observability_contract
// required, checked in CI, not documentation) -- observability/spans.yaml's
// declared span names are diffed against the REAL span names a Recording
// tracer observes when driven through Ledger.Deposit/Withdraw, in both
// directions.
func TestSpansYAML_MatchesLedgerSpanNames(t *testing.T) {
	declared := parseSpanNames(t, spansManifestPath(t))

	rec := observability.NewRecording()
	l, _, _ := newTestLedger()
	l.SetTracer(func(name string, attrs map[string]string) func(error) {
		_, span := rec.StartSpan(context.Background(), name, attrs)
		return func(err error) {
			span.RecordError(err)
			span.End()
		}
	})
	if _, err := l.Deposit(context.Background(), "e1", "10"); err != nil {
		t.Fatalf("Deposit: %v", err)
	}
	if _, err := l.Withdraw(context.Background(), "e2", "5"); err != nil {
		t.Fatalf("Withdraw: %v", err)
	}

	emitted := map[string]bool{}
	for _, s := range rec.Spans {
		emitted[s.Name] = true
	}

	for name := range declared {
		if !emitted[name] {
			t.Errorf("observability/spans.yaml declares span %q that Ledger never emits", name)
		}
	}
	for name := range emitted {
		if !declared[name] {
			t.Errorf("Ledger emits span %q that observability/spans.yaml does not declare", name)
		}
	}
}

// provenance: derived
// verifies: observability contract (RecordError is wired to real error
// paths, not a no-op that nothing ever calls with a non-nil error)
func TestSpans_RecordErrorFiresOnAFailingCommand(t *testing.T) {
	rec := observability.NewRecording()
	l, j, _ := newTestLedger()
	l.SetTracer(func(name string, attrs map[string]string) func(error) {
		_, span := rec.StartSpan(context.Background(), name, attrs)
		return func(err error) {
			span.RecordError(err)
			span.End()
		}
	})
	j.failNext = true
	if _, err := l.Deposit(context.Background(), "e1", "10"); err == nil {
		t.Fatal("Deposit did not error despite a simulated journal failure")
	}
	spans := rec.Named("svc.deposit")
	if len(spans) != 1 || spans[0].Err == nil {
		t.Fatalf("svc.deposit span = %+v, want exactly one span with a recorded error", spans)
	}
}

func spansManifestPath(t *testing.T) string {
	t.Helper()
	return filepath.Join(repoRootForContractTest(t), "observability", "spans.yaml")
}

func repoRootForContractTest(t *testing.T) string {
	t.Helper()
	_, currentFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot locate this test file")
	}
	// this file: internal/app/tracing_contract_test.go
	return filepath.Clean(filepath.Join(filepath.Dir(currentFile), "..", ".."))
}

var spanNameLineRe = regexp.MustCompile(`^- name:\s*(\S+)\s*$`)

func parseSpanNames(t *testing.T, path string) map[string]bool {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	out := map[string]bool{}
	for _, line := range strings.Split(string(data), "\n") {
		if m := spanNameLineRe.FindStringSubmatch(line); m != nil {
			out[m[1]] = true
		}
	}
	if len(out) == 0 {
		t.Fatalf("parsed zero span names from %s -- format changed or the scanner broke", path)
	}
	return out
}
