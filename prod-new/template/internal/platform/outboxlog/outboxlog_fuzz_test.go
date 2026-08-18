package outboxlog

import "testing"

// provenance: derived
// verifies: DecodeRecord is a decode boundary (Replay feeds it whatever bytes
// are on disk, which after a partial write, disk corruption or a hand-edited
// file may not be valid JSON at all) and must never panic.
func FuzzDecodeOutboxRecord(f *testing.F) {
	for _, seed := range []string{
		`{"schema_version":1,"entry_id":"e1","state":"intent","idempotency_key":"k","effect":{"kind":"deposited","event_id":"d","amount":"1"}}`,
		`{"schema_version":1,"entry_id":"e1","state":"delivered","attempts":2}`,
		`{"schema_version":2,"entry_id":"e1","state":"intent"}`,
		`{"schema_version":1,"entry_id":"","state":"intent"}`,
		`{"schema_version":1,"entry_id":"e1","state":"\ud800"}`,
		`{}`, `[]`, `null`, ``, `not json`, `{"effect":{"kind":123}}`,
	} {
		f.Add(seed)
	}
	f.Fuzz(func(t *testing.T, s string) {
		defer func() {
			if r := recover(); r != nil {
				t.Fatalf("DecodeRecord(%q) panicked: %v", s, r)
			}
		}()
		rec, err := DecodeRecord([]byte(s))
		if err != nil {
			return
		}
		// A record that decodes must also be foldable without a panic.
		_, _ = Rebuild([]Record{rec})
	})
}
