package invoice

import "testing"

func TestSubtotalAndTax(t *testing.T) {
	inv := Invoice{Lines: []Line{
		{Desc: "widget", UnitCents: 1999, Qty: 3},
		{Desc: "gadget", UnitCents: 501, Qty: 1},
	}}
	if got := inv.Subtotal(); got != 6498 {
		t.Fatalf("Subtotal = %d, want 6498", got)
	}
	if got := inv.Tax(825); got != 536 {
		t.Fatalf("Tax = %d, want 536", got)
	}
}

func TestFormat(t *testing.T) {
	if got := Format(1999); got != "19.99" {
		t.Fatalf("Format = %q", got)
	}
}
