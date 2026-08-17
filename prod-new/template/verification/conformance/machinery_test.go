package conformance

import "testing"

// provenance: derived
// verifies: conformance kit machinery is real for EVERY declared class
// (tier-policy: conformance kits GATE at T0), not only the ones this
// template's scaffold happens to have a live adapter for yet. A trivial
// drive proves each kit iterates its FULL declared scenario list -- the
// same assertion TestExternalEffectKit_DrivesEveryDeclaredScenario makes
// for the one class with a real wired adapter (internal/adapter/out/store),
// applied here to the four classes this scaffold has not grown an adapter
// for.
func TestRemainingKits_DriveEveryDeclaredScenario(t *testing.T) {
	cases := []struct {
		name      string
		run       func(t *testing.T, drive func(t *testing.T, scenario string))
		scenarios []string
	}{
		{"connection", ConnectionKit, ConnectionScenarios},
		{"event_consumer", EventConsumerKit, EventConsumerScenarios},
		{"event_producer", EventProducerKit, EventProducerScenarios},
		{"signer", SignerKit, SignerScenarios},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			seen := map[string]bool{}
			tc.run(t, func(t *testing.T, scenario string) {
				seen[scenario] = true
				t.Skipf("class %q has no live adapter in this scaffold yet -- the next capability of this class plugs in here, mirroring internal/adapter/out/store's own conformance_kit_test.go", tc.name)
			})
			for _, want := range tc.scenarios {
				if !seen[want] {
					t.Errorf("%s kit never drove scenario %q", tc.name, want)
				}
			}
		})
	}
}
