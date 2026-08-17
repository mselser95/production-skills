package healthhttp

import (
	"testing"
	"time"

	"github.com/<OWNER>/<SERVICE>/verification/conformance"
)

// provenance: derived
// verifies: capability health_metrics_surface / external_read conformance
// kit (tier-policy: conformance kits GATE at T0)
//
// This is a DRIVING adapter serving THIS process's own internal state, not
// a client reading an external system's response over the network -- so
// several scenarios in external_read's checklist (written for a real
// upstream dependency) are N/A by construction, documented below rather
// than silently skipped. The two that DO have real teeth here
// (staleness/unavailability of the internal state this surface reports)
// are exercised for real.
func TestServer_PassesExternalReadConformanceKit(t *testing.T) {
	conformance.ExternalReadKit(t, driveExternalRead)
}

func driveExternalRead(t *testing.T, scenario string) {
	switch scenario {
	case "stale_data":
		// TestReadinessAt_RecentViolationGatesReadiness_ThenClearsAfterCooldown
		// (health_test.go) already proves the SAME obligation this scenario
		// asks for: a recent invariant violation makes /readyz report
		// not-ready until ViolationCooldown elapses, and ReadinessAt's
		// Checks.NoRecentInvariantViolation makes the staleness OBSERVABLE
		// to the caller, not just internally tracked.
		violatedAt := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
		srv := New(fakeLedger{lastViolation: violatedAt}, Options{Log: fakeLog{writable: true}, ViolationCooldown: time.Minute})
		ready, checks := srv.ReadinessAt(violatedAt.Add(time.Second))
		if ready || checks.NoRecentInvariantViolation {
			t.Fatalf("ready=%v checks=%+v immediately after a violation, want stale/not-ready", ready, checks)
		}

	case "unavailable":
		// TestReadyz_NoLogIsNotReady already proves this at the HTTP level;
		// re-asserted here directly against ReadinessAt for the kit's own
		// record.
		srv := New(fakeLedger{}, Options{}) // no log configured -> unavailable
		ready, checks := srv.ReadinessAt(time.Now())
		if ready || checks.LogWritable {
			t.Fatalf("ready=%v checks=%+v with no log configured, want unavailable", ready, checks)
		}

	case "gap":
		t.Skip("this surface reports point-in-time state (current readiness/counters), not a sequenced/versioned feed -- there is no sequence-number space in which a \"gap\" is a meaningful concept")

	case "malformed_response":
		t.Skip("this handler RENDERS its own JSON/Prometheus-text response from data it controls -- it is not a client parsing an untrusted external response, so there is no malformed-response-from-upstream case to defend against at this layer")

	case "slow_response":
		t.Skip("every read behind /healthz, /readyz and /metrics is an in-memory field read (LedgerHealth/EventLogHealth are simple accessors) -- there is no external round trip that could be slow")

	default:
		t.Fatalf("conformance kit scenario %q has no driver in this test -- add one instead of letting it silently pass", scenario)
	}
}
