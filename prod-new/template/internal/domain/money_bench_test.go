package domain

import (
	"strconv"
	"testing"
)

// Benchmarks record, never gate (tier-policy.yaml: benchmarks.comparison =
// statistical_relative_only) -- see benchmarks/baseline-*.txt for the
// recorded reference and benchmarks/README.md for how to compare against
// it.
func BenchmarkParseAmount(b *testing.B) {
	for i := 0; i < b.N; i++ {
		if _, err := ParseAmount("123456789.12345678"); err != nil {
			b.Fatal(err)
		}
	}
}

func BenchmarkAddAmounts(b *testing.B) {
	for i := 0; i < b.N; i++ {
		if _, err := AddAmounts("100.50000000", "0.00000001"); err != nil {
			b.Fatal(err)
		}
	}
}

func BenchmarkApply_Deposit(b *testing.B) {
	state := NewState()
	for i := 0; i < b.N; i++ {
		// A fresh ID per iteration: reusing one would measure the
		// idempotency no-op path after the first call, not a real deposit.
		state, _ = Apply(state, Event{ID: strconv.Itoa(i), Type: EventDeposited, Amount: "1"})
	}
}
