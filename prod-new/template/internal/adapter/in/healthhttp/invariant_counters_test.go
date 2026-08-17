package healthhttp

import (
	"testing"
	"time"
)

// provenance: derived
// verifies: readiness-gate self-audit -- auditReadyzNeverLiesAboutItsOwnGates
// is pure and exercised directly with a deliberately violating input, proving
// the predicate correctly distinguishes a contradiction from every
// legitimate combination.
func TestAuditReadyzNeverLiesAboutItsOwnGates_DetectsAndRejectsCorrectly(t *testing.T) {
	cases := []struct {
		name                 string
		ready, logOK, violOK bool
		wantMismatch         bool
	}{
		{"violation: ready while log gate failing", true, false, true, true},
		{"violation: ready while violation gate failing", true, true, false, true},
		{"correct: ready and both gates pass", true, true, true, false},
		{"correct: not ready, log failing", false, false, true, false},
		{"correct: not ready, violation gate failing", false, true, false, false},
		{"correct: not ready, both failing", false, false, false, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := auditReadyzNeverLiesAboutItsOwnGates(tc.ready, tc.logOK, tc.violOK); got != tc.wantMismatch {
				t.Fatalf("auditReadyzNeverLiesAboutItsOwnGates(%v,%v,%v)=%v, want %v", tc.ready, tc.logOK, tc.violOK, got, tc.wantMismatch)
			}
		})
	}
}

// provenance: derived
// verifies: readiness-gate self-audit counter is wired, not dead code -- a
// deliberate direct call must increment it.
func TestStaleReadyAudits_IncrementsOnDeliberateViolation(t *testing.T) {
	srv := New(fakeLedger{}, Options{})
	srv.RecordStaleReadyAuditForTest()
	if got := srv.StaleReadyAudits(); got != 1 {
		t.Fatalf("StaleReadyAudits=%d after one deliberate call, want 1", got)
	}
}

// provenance: derived
// verifies: readiness-gate self-audit counter stays 0 across every shape
// ReadinessAt's real formula can produce.
func TestStaleReadyAudits_StaysZeroUnderNormalOperation(t *testing.T) {
	srv := New(fakeLedger{}, Options{Log: fakeLog{writable: true}})
	srv.ReadinessAt(time.Now())
	srv2 := New(fakeLedger{}, Options{})
	srv2.ReadinessAt(time.Now())
	if got := srv.StaleReadyAudits(); got != 0 {
		t.Fatalf("StaleReadyAudits=%d after only real ReadinessAt evaluations, want 0", got)
	}
	if got := srv2.StaleReadyAudits(); got != 0 {
		t.Fatalf("StaleReadyAudits=%d after only real ReadinessAt evaluations, want 0", got)
	}
}
