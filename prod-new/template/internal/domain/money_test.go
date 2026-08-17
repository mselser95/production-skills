package domain

import "testing"

// provenance: derived
// verifies: money math correctness (ParseAmount/FormatAmount round-trip)
func TestParseAmount_ValidInputsRoundTripThroughFormatAmount(t *testing.T) {
	cases := []struct{ in, want string }{
		{"0", ZeroAmount},
		{"0.0", ZeroAmount},
		{"1", "1.00000000"},
		{"1.5", "1.50000000"},
		{"1.00000001", "1.00000001"},
		{"123456789.12345678", "123456789.12345678"},
		{"0.00000000", ZeroAmount},
	}
	for _, tc := range cases {
		t.Run(tc.in, func(t *testing.T) {
			units, err := ParseAmount(tc.in)
			if err != nil {
				t.Fatalf("ParseAmount(%q): %v", tc.in, err)
			}
			got := FormatAmount(units)
			if got != tc.want {
				t.Fatalf("FormatAmount(ParseAmount(%q)) = %q, want %q", tc.in, got, tc.want)
			}
		})
	}
}

// provenance: derived
// verifies: money math correctness (ParseAmount rejects malformed input --
// the decode boundary FuzzParseAmount also drives)
func TestParseAmount_RejectsMalformedInput(t *testing.T) {
	cases := []struct {
		in      string
		wantErr error
	}{
		{"", ErrMalformedAmount},
		{"-1", ErrNegativeAmount},
		{"-0.5", ErrNegativeAmount},
		{"+1", ErrMalformedAmount},
		{"1e10", ErrMalformedAmount},
		{"1,000", ErrMalformedAmount},
		{" 1", ErrMalformedAmount},
		{"1 ", ErrMalformedAmount},
		{"abc", ErrMalformedAmount},
		{".5", ErrMalformedAmount},
		{"1.", ErrMalformedAmount},
		{"1.2.3", ErrMalformedAmount},
		{"NaN", ErrMalformedAmount},
		{"Inf", ErrMalformedAmount},
		{"1.123456789", ErrTooManyFractionalDigits}, // 9 fractional digits > Scale
		{"١", ErrMalformedAmount},                   // arabic-indic digit one, not ASCII
	}
	for _, tc := range cases {
		t.Run(tc.in, func(t *testing.T) {
			_, err := ParseAmount(tc.in)
			if err != tc.wantErr {
				t.Fatalf("ParseAmount(%q) err = %v, want %v", tc.in, err, tc.wantErr)
			}
		})
	}
}

// provenance: derived
// verifies: money math correctness (FormatAmount panics rather than silently
// rendering a negative ledger amount, which this domain forbids by
// construction)
func TestFormatAmount_PanicsOnNegative(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Fatal("FormatAmount did not panic on a negative value")
		}
	}()
	units, err := ParseAmount("5")
	if err != nil {
		t.Fatalf("ParseAmount: %v", err)
	}
	units.Neg(units)
	FormatAmount(units)
}

// provenance: derived
// verifies: money math correctness (AddAmounts/SubAmounts/CompareAmounts)
func TestAddSubCompareAmounts(t *testing.T) {
	sum, err := AddAmounts("1.5", "2.25")
	if err != nil {
		t.Fatalf("AddAmounts: %v", err)
	}
	if sum != "3.75000000" {
		t.Fatalf("AddAmounts(1.5, 2.25) = %q, want 3.75000000", sum)
	}

	diff, err := SubAmounts("3.75", "2.25")
	if err != nil {
		t.Fatalf("SubAmounts: %v", err)
	}
	if diff != "1.50000000" {
		t.Fatalf("SubAmounts(3.75, 2.25) = %q, want 1.50000000", diff)
	}

	if _, err := SubAmounts("1", "2"); err != ErrInsufficientAmount {
		t.Fatalf("SubAmounts(1, 2) err = %v, want ErrInsufficientAmount", err)
	}

	if _, err := AddAmounts("bad", "1"); err == nil {
		t.Fatal("AddAmounts with a malformed first operand did not error")
	}
	if _, err := AddAmounts("1", "bad"); err == nil {
		t.Fatal("AddAmounts with a malformed second operand did not error")
	}
	if _, err := SubAmounts("bad", "1"); err == nil {
		t.Fatal("SubAmounts with a malformed first operand did not error")
	}
	if _, err := SubAmounts("2", "bad"); err == nil {
		t.Fatal("SubAmounts with a malformed second operand did not error")
	}
	if _, err := CompareAmounts("bad", "1"); err == nil {
		t.Fatal("CompareAmounts with a malformed first operand did not error")
	}
	if _, err := CompareAmounts("1", "bad"); err == nil {
		t.Fatal("CompareAmounts with a malformed second operand did not error")
	}

	cmp, err := CompareAmounts("1.1", "1.10000000")
	if err != nil {
		t.Fatalf("CompareAmounts: %v", err)
	}
	if cmp != 0 {
		t.Fatalf("CompareAmounts(1.1, 1.10000000) = %d, want 0 (same canonical value)", cmp)
	}

	if cmp, _ := CompareAmounts("1", "2"); cmp != -1 {
		t.Fatalf("CompareAmounts(1, 2) = %d, want -1", cmp)
	}
	if cmp, _ := CompareAmounts("2", "1"); cmp != 1 {
		t.Fatalf("CompareAmounts(2, 1) = %d, want 1", cmp)
	}
}

// provenance: derived
// verifies: money math correctness (ValidateAmount is ParseAmount's error-
// only view, used by domain.Apply's guard)
func TestValidateAmount(t *testing.T) {
	if err := ValidateAmount("1.23"); err != nil {
		t.Fatalf("ValidateAmount(1.23): %v", err)
	}
	if err := ValidateAmount("-1"); err == nil {
		t.Fatal("ValidateAmount(-1) = nil, want an error")
	}
}
