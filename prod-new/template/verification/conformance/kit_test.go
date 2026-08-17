package conformance

import "testing"

// provenance: derived
// verifies: conformance kit machinery itself is real (tier-policy:
// conformance kits GATE at T0) -- a kit invoked with an empty scenario
// list must fail loudly rather than vacuously pass, and every declared
// class's scenario list must be non-empty.
func TestConformanceKits_EveryClassHasANonEmptyScenarioList(t *testing.T) {
	classes := map[string][]string{
		"connection":      ConnectionScenarios,
		"event_consumer":  EventConsumerScenarios,
		"event_producer":  EventProducerScenarios,
		"external_read":   ExternalReadScenarios,
		"external_effect": ExternalEffectScenarios,
		"source_of_truth": SourceOfTruthScenarios,
		"signer":          SignerScenarios,
	}
	for name, scenarios := range classes {
		if len(scenarios) == 0 {
			t.Errorf("class %q has an empty scenario list", name)
		}
	}
}

// provenance: derived
// verifies: conformance kit machinery (the guard scenarioKit calls before
// running anything rejects an empty scenario list and a nil drive func --
// exercised directly since observing a live t.Fatal from inside a nested
// *testing.T is not a meaningful assertion)
func TestValidateKit_RejectsEmptyScenarioListAndNilDrive(t *testing.T) {
	noop := func(*testing.T, string) {}
	if err := validateKit("x", nil, noop); err == nil {
		t.Fatal("validateKit did not reject an empty scenario list")
	}
	if err := validateKit("x", []string{"a"}, nil); err == nil {
		t.Fatal("validateKit did not reject a nil drive func")
	}
	if err := validateKit("x", []string{"a"}, noop); err != nil {
		t.Fatalf("validateKit rejected a valid (class, scenarios, drive) triple: %v", err)
	}
}

// provenance: derived
// verifies: every XxxKit runs its full checklist as subtests (not just a
// single pass/fail) -- driven with a drive func that records which
// scenarios it was called with, so the count is asserted, not assumed.
func TestExternalEffectKit_DrivesEveryDeclaredScenario(t *testing.T) {
	seen := map[string]bool{}
	ExternalEffectKit(t, func(t *testing.T, scenario string) {
		seen[scenario] = true
	})
	for _, want := range ExternalEffectScenarios {
		if !seen[want] {
			t.Errorf("ExternalEffectKit never drove scenario %q", want)
		}
	}
}
