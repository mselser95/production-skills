package healthhttp

// auditReadyzNeverLiesAboutItsOwnGates is a pure, directly-testable
// predicate: given the THREE values ReadinessAt just computed (the overall
// `ready` verdict and its two component gates), does `ready` actually
// match `logOK && violationOK`? ReadinessAt's own formula can never
// disagree with itself -- `ready := logOK && violationOK` is the whole
// implementation -- so in real operation this predicate can never observe
// a mismatch. It exists, and is called on every ReadinessAt evaluation via
// auditReadiness below, so the counter it drives is proven to be wired to
// something that CAN fire (see TestAuditReadyzNeverLiesAboutItsOwnGates in
// health_test.go, which calls it directly with a deliberately inconsistent
// triple), rather than being dead defensive code nothing ever exercises.
func auditReadyzNeverLiesAboutItsOwnGates(ready, logOK, violationOK bool) bool {
	return ready != (logOK && violationOK)
}

// auditReadiness runs the audit above against the values this evaluation
// just computed and increments staleReadyAudits if it ever finds a
// mismatch.
func (s *Server) auditReadiness(ready, logOK, violationOK bool) {
	if auditReadyzNeverLiesAboutItsOwnGates(ready, logOK, violationOK) {
		s.recordStaleReadyAudit()
	}
}

func (s *Server) recordStaleReadyAudit() {
	s.staleReadyAudits.Add(1)
}

// StaleReadyAudits returns how many times auditReadiness has detected
// /readyz's own `ready` verdict disagreeing with its component gates. Must
// stay 0 under every real evaluation -- see
// svc_readyz_stale_never_ready_audits_total in /metrics.
func (s *Server) StaleReadyAudits() int64 { return s.staleReadyAudits.Load() }

// RecordStaleReadyAuditForTest calls the exact same increment path
// auditReadiness uses, directly, with a deliberately violating call --
// proving the counter is wired without needing ReadinessAt's own formula
// (which can never itself produce a mismatch) to be mutated to manufacture
// one.
func (s *Server) RecordStaleReadyAuditForTest() {
	s.recordStaleReadyAudit()
}
