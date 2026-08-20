package app

import (
	"context"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/<OWNER>/<SERVICE>/internal/domain"
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
	l.SetTracer(func(ctx context.Context, name string, attrs map[string]string) (context.Context, func(error)) {
		ctx, span := rec.StartSpan(ctx, name, attrs)
		return ctx, func(err error) {
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
	l.SetTracer(func(ctx context.Context, name string, attrs map[string]string) (context.Context, func(error)) {
		ctx, span := rec.StartSpan(ctx, name, attrs)
		return ctx, func(err error) {
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

// spanCtxKey marks a context so the guard below can tell a span-carrying
// context from the bare one the caller passed in.
type spanCtxKey struct{}

// ctxRecordingJournal records the context Append was handed, which is the
// only way to see whether process() threads the SPAN's context downstream or
// silently drops it.
type ctxRecordingJournal struct {
	fakeJournal
	gotCtx context.Context
}

func (j *ctxRecordingJournal) Append(ctx context.Context, e domain.Event) error {
	j.gotCtx = ctx
	return j.fakeJournal.Append(ctx, e)
}

// provenance: regression
// verifies: observability -- the context returned by SpanFunc REACHES the
// ledger's durable write, on EVERY entry point that has one.
//
// This is the half of trace correlation that lives below the log call sites.
// Converting every logger.Info to InfoContext is necessary and useless on its
// own: a *Context call can only carry a trace id if some context in scope
// actually contains the span. And here it decides something durable -- the
// journal records the traceparent it finds in this context, so a dropped
// context means every published event is an orphan root forever, in bytes on
// disk, not just in this process.
//
// TABLE-DRIVEN because the rule has TWO call sites and a single row plus an
// assumption is how the second one goes unguarded: `_, end := l.spanStart(...)`
// in process() is one edit, and it must fail loudly for both commands.
func TestSpanContextReachesTheLedgersDurableWrite(t *testing.T) {
	tests := []struct {
		name string
		span string
		call func(*Ledger, context.Context) error
	}{
		{
			name: "Deposit",
			span: "svc.deposit",
			call: func(l *Ledger, ctx context.Context) error {
				_, err := l.Deposit(ctx, "e1", "10")
				return err
			},
		},
		{
			name: "Withdraw",
			span: "svc.withdraw",
			call: func(l *Ledger, ctx context.Context) error {
				_, err := l.Withdraw(ctx, "e2", "0")
				return err
			},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			j := &ctxRecordingJournal{}
			l := NewLedger(domain.NewState(), j, nil,
				func() time.Time { return time.Unix(1_700_000_000, 0) },
				func() string { return "gen-1" })
			l.SetTracer(func(ctx context.Context, name string, _ map[string]string) (context.Context, func(error)) {
				return context.WithValue(ctx, spanCtxKey{}, name), func(error) {}
			})

			if err := test.call(l, context.Background()); err != nil {
				t.Fatalf("%s: %v", test.name, err)
			}
			if j.gotCtx == nil {
				t.Fatal("Append was never called")
			}
			if got := j.gotCtx.Value(spanCtxKey{}); got != test.span {
				t.Fatalf("the journal received a context WITHOUT the span (%v) -- the traceparent "+
					"it persists is empty, so the relay's later publish of this fact is an orphan "+
					"root that can never be joined to the command that decided it", got)
			}
		})
	}
}
