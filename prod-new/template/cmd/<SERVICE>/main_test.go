package main

import (
	"errors"
	"testing"

	"github.com/<OWNER>/<SERVICE>/internal/platform/observability"
)

// provenance: derived
// verifies: composition root (portAddr's ephemeral-vs-fixed port selection,
// the one piece of this file with a return value worth pinning directly --
// the rest of main() is process-wiring glue exercised end to end by
// internal/e2e's integration-tagged test instead, per the standard's own
// "don't pad coverage on process glue" discipline)
func TestPortAddr(t *testing.T) {
	if got := portAddr(0); got != "127.0.0.1:0" {
		t.Fatalf("portAddr(0) = %q, want 127.0.0.1:0", got)
	}
	if got := portAddr(9090); got != ":9090" {
		t.Fatalf("portAddr(9090) = %q, want :9090", got)
	}
}

// provenance: derived
// verifies: the composition root's ONE piece of real bridging logic --
// adaptTracer -- correctly wires observability.Tracer's StartSpan/End/
// RecordError into internal/app.SpanFunc's shape, in both the success and
// error case, so an error passed to the returned func actually reaches the
// underlying Span.RecordError before End is called.
func TestAdaptTracer(t *testing.T) {
	rec := observability.NewRecording()
	spanFn := adaptTracer(rec)

	end := spanFn("svc.deposit", map[string]string{"event_type": "deposited"})
	end(nil)

	end2 := spanFn("svc.withdraw", map[string]string{"event_type": "withdrawn"})
	end2(errors.New("boom"))

	deposits := rec.Named("svc.deposit")
	if len(deposits) != 1 || deposits[0].Err != nil {
		t.Fatalf("svc.deposit span = %+v, want one span with no error", deposits)
	}
	withdrawals := rec.Named("svc.withdraw")
	if len(withdrawals) != 1 || withdrawals[0].Err == nil {
		t.Fatalf("svc.withdraw span = %+v, want one span with a recorded error", withdrawals)
	}
}
