// Package conformance holds the org's PER-CAPABILITY-CLASS behavioral test
// kits (tier-policy.yaml: capability_classes). A capability CLASS defines a
// reusable behavioral checklist, and every adapter implementing a
// capability of that class must pass its class's kit -- that is what makes
// "this adapter satisfies its port contract" a mechanical claim instead of
// a comment.
//
// Each Kit function here runs the class's WHOLE scenario checklist as
// subtests, one per scenario, via a `drive` closure the adapter's own test
// file supplies. See README.md for the full contract, including what
// changing a scenario list here requires (a tier-policy.yaml ratification,
// never a local test edit).
package conformance

import (
	"fmt"
	"testing"
)

// validateKit is scenarioKit's guard, factored out as a pure function so it
// is directly unit-testable (see kit_test.go) without needing to observe a
// t.Fatalf from inside a live *testing.T.
func validateKit(className string, scenarios []string, drive func(t *testing.T, scenario string)) error {
	if len(scenarios) == 0 {
		return fmt.Errorf("%s: scenario checklist is empty -- a kit with no scenarios would vacuously pass", className)
	}
	if drive == nil {
		return fmt.Errorf("%s: kit called with a nil drive func", className)
	}
	return nil
}

// scenarioKit is the shared machinery behind every class's exported Kit
// function below.
func scenarioKit(t *testing.T, className string, scenarios []string, drive func(t *testing.T, scenario string)) {
	t.Helper()
	if err := validateKit(className, scenarios, drive); err != nil {
		t.Fatal(err)
	}
	for _, scenario := range scenarios {
		t.Run(scenario, func(t *testing.T) { drive(t, scenario) })
	}
}

// ConnectionScenarios is capability class "connection"'s fixed scenario
// checklist (tier-policy.yaml: capability_classes.connection.scenarios).
var ConnectionScenarios = []string{
	"disconnect",
	"sequence_gap",
	"missed_heartbeat",
	"reconnect_storm",
	"half_open_socket",
	"resubscribe_failure",
	"scheduled_recycle",
}

// ConnectionKit runs class "connection"'s checklist. `drive` must exercise
// the adapter through its port for the named scenario and assert the
// class's declared obligations (reconnect_policy, liveness_detection,
// resubscribe_semantics, readiness_gating), or t.Skip with an explicit
// reason.
func ConnectionKit(t *testing.T, drive func(t *testing.T, scenario string)) {
	t.Helper()
	scenarioKit(t, "connection", ConnectionScenarios, drive)
}

// EventConsumerScenarios is capability class "event_consumer"'s fixed
// scenario checklist.
var EventConsumerScenarios = []string{
	"duplicate",
	"delay",
	"reorder",
	"drop",
	"poison_message",
	"partition",
	"upstream_backpressure",
}

// EventConsumerKit runs class "event_consumer"'s checklist. `drive` must
// assert the class's declared obligations (delivery_semantics,
// ordering_semantics, duplicate_handling, poison_handling, backpressure),
// or t.Skip with an explicit reason.
func EventConsumerKit(t *testing.T, drive func(t *testing.T, scenario string)) {
	t.Helper()
	scenarioKit(t, "event_consumer", EventConsumerScenarios, drive)
}

// EventProducerScenarios is capability class "event_producer"'s fixed
// scenario checklist.
var EventProducerScenarios = []string{
	"slow_consumer",
	"consumer_disconnect",
	"publish_failure",
	"replay",
}

// EventProducerKit runs class "event_producer"'s checklist. `drive` must
// assert the class's declared obligations (delivery_semantics,
// ordering_guarantee, observability), or t.Skip with an explicit reason.
func EventProducerKit(t *testing.T, drive func(t *testing.T, scenario string)) {
	t.Helper()
	scenarioKit(t, "event_producer", EventProducerScenarios, drive)
}

// ExternalReadScenarios is capability class "external_read"'s fixed
// scenario checklist.
var ExternalReadScenarios = []string{
	"stale_data",
	"gap",
	"malformed_response",
	"unavailable",
	"slow_response",
}

// ExternalReadKit runs class "external_read"'s checklist. `drive` must
// assert the class's declared obligations (max_age_declared,
// staleness_observable, unavailable_fallback, timeout), or t.Skip with an
// explicit reason.
func ExternalReadKit(t *testing.T, drive func(t *testing.T, scenario string)) {
	t.Helper()
	scenarioKit(t, "external_read", ExternalReadScenarios, drive)
}

// ExternalEffectScenarios is capability class "external_effect"'s fixed
// scenario checklist. internal/adapter/out/store is this template's wired
// example -- see its conformance_kit_test.go.
var ExternalEffectScenarios = []string{
	"rejected",
	"timeout_before_acceptance",
	"timeout_after_acceptance",
	"duplicate_response",
	"malformed_response",
	"unavailable",
	"extreme_latency",
	"crash_between_decision_and_effect",
	"retry_on_unknown_state",
}

// ExternalEffectKit runs class "external_effect"'s checklist. `drive` must
// assert the class's declared obligations (timeout, retry_policy,
// failure_model, idempotency_strategy, reconciliation, observability), or
// t.Skip with an explicit reason.
func ExternalEffectKit(t *testing.T, drive func(t *testing.T, scenario string)) {
	t.Helper()
	scenarioKit(t, "external_effect", ExternalEffectScenarios, drive)
}

// SourceOfTruthScenarios is capability class "source_of_truth"'s fixed
// scenario checklist. Written for a durable store with a client/server
// boundary and a commit protocol; an in-process, single-writer structure
// (like this template's internal/domain.State, held in memory by
// internal/app.Ledger) is expected to t.Skip most of these with an
// explicit reason -- see README.md.
var SourceOfTruthScenarios = []string{
	"deadlock",
	"serialization_conflict",
	"timeout",
	"commit_ok_response_lost",
	"connection_dies_before_commit",
	"connection_dies_after_commit",
	"restore_from_backup",
}

// SourceOfTruthKit runs class "source_of_truth"'s checklist. `drive` must
// assert the class's declared obligations (consistency_semantics,
// recovery, backup, reconciliation), or t.Skip with an explicit, documented
// reason when a scenario does not apply.
func SourceOfTruthKit(t *testing.T, drive func(t *testing.T, scenario string)) {
	t.Helper()
	scenarioKit(t, "source_of_truth", SourceOfTruthScenarios, drive)
}

// SignerScenarios is capability class "signer"'s fixed scenario checklist.
var SignerScenarios = []string{
	"unauthorized_request",
	"policy_violation",
	"key_unavailable",
	"partial_quorum",
}

// SignerKit runs class "signer"'s checklist. `drive` must assert the
// class's declared obligations (key_custody, policy_enforcement,
// audit_trail, quorum), or t.Skip with an explicit reason. This template
// declares no signer capability -- the kit exists so the FIRST real one
// added to a service born from this template has somewhere to plug in,
// per RULE BORN-COMPLETE.
func SignerKit(t *testing.T, drive func(t *testing.T, scenario string)) {
	t.Helper()
	scenarioKit(t, "signer", SignerScenarios, drive)
}
