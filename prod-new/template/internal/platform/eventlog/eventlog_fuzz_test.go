package eventlog

import "testing"

// provenance: derived
// verifies: decodeRecord is a decode boundary (Replay feeds it whatever
// bytes are on disk, which -- after a partial write, disk corruption, or a
// hand-edited file -- may not be valid JSON at all) and must never panic.
func FuzzDecodeRecord(f *testing.F) {
	for _, seed := range []string{
		`{"schema_version":1,"id":"e1","type":"deposited","amount":"10"}`,
		`{"schema_version":2,"kind":"event","id":"e1","type":"deposited","amount":"10"}`,
		`{"schema_version":2,"kind":"snapshot","state":{"Balance":"1.0","Applied":{"a":true},"Version":1}}`,
		`{"schema_version":2,"kind":"snapshot","state":null}`,
		`{"schema_version":2,"kind":"snapshot"}`,
		`{"schema_version":2,"kind":"snapshot","state":"not an object"}`,
		`{"schema_version":2,"kind":"","id":"e1","type":"deposited","amount":"10"}`,
		`{"schema_version":2,"kind":"wat","id":"e1"}`,
		`{"schema_version":3,"kind":"event"}`,
		`{}`,
		`not json at all`,
		`{"schema_version":1}`,
		`{"schema_version":"one","id":"e1"}`,
		`[]`,
		`null`,
		``,
	} {
		f.Add(seed)
	}
	f.Fuzz(func(t *testing.T, s string) {
		defer func() {
			if r := recover(); r != nil {
				t.Fatalf("decodeRecord(%q) panicked: %v", s, r)
			}
		}()
		_, _ = decodeRecord([]byte(s))
	})
}
