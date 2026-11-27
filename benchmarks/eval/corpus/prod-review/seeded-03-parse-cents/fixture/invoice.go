package invoice

import "fmt"

// Line is one invoice line; prices are integer cents.
type Line struct {
	Desc      string
	UnitCents int64
	Qty       int64
}

// Total is the line total in cents.
func (l Line) Total() int64 { return l.UnitCents * l.Qty }

// Invoice is a list of lines.
type Invoice struct {
	Lines []Line
}

// Subtotal sums the line totals in cents.
func (i Invoice) Subtotal() int64 {
	var s int64
	for _, l := range i.Lines {
		s += l.Total()
	}
	return s
}

// Tax returns the tax on the subtotal at bps basis points, rounded half up.
func (i Invoice) Tax(bps int64) int64 {
	return (i.Subtotal()*bps + 5000) / 10000
}

// Format renders cents as a decimal amount, e.g. 1999 -> "19.99".
func Format(cents int64) string {
	return fmt.Sprintf("%d.%02d", cents/100, cents%100)
}
