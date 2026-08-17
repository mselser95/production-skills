package domain

import "testing"

// provenance: derived
// verifies: ParseAmount is the sole decode boundary for caller-supplied
// amount strings and must never panic, whatever it is handed.
//
// Two properties are checked on every input:
//  1. ParseAmount never panics (the fuzzer itself catches that).
//  2. When ParseAmount succeeds, FormatAmount(units) must itself be a valid
//     ParseAmount input that round-trips to the SAME parsed value -- i.e.
//     the canonical form is stable under one more parse/format cycle.
func FuzzParseAmount(f *testing.F) {
	for _, seed := range []string{
		"0", "0.0", "1", "1.5", "1.00000001", "123456789.12345678",
		"", "-1", "+1", "1e10", "1,000", " 1", "1 ", "abc", ".5", "1.",
		"1.2.3", "NaN", "Inf", "1.123456789", "٠", "00000", "0000.00001",
		"99999999999999999999999999999999999999.99999999",
	} {
		f.Add(seed)
	}
	f.Fuzz(func(t *testing.T, s string) {
		units, err := ParseAmount(s)
		if err != nil {
			return
		}
		if units.Sign() < 0 {
			t.Fatalf("ParseAmount(%q) returned a negative value %v with no error", s, units)
		}
		canonical := FormatAmount(units)
		units2, err2 := ParseAmount(canonical)
		if err2 != nil {
			t.Fatalf("ParseAmount(%q) succeeded but its own FormatAmount output %q does not re-parse: %v", s, canonical, err2)
		}
		if units.Cmp(units2) != 0 {
			t.Fatalf("round-trip mismatch: ParseAmount(%q)=%v but ParseAmount(FormatAmount(...))=%v", s, units, units2)
		}
	})
}
