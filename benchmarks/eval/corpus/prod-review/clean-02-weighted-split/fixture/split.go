package split

import "errors"

// ErrInput is returned for a negative total or a bad party count.
var ErrInput = errors.New("invalid split input")

// Even divides total cents between n parties. The shares sum to total; the
// first total%n parties get one extra cent.
func Even(total int64, n int) ([]int64, error) {
	if total < 0 || n <= 0 {
		return nil, ErrInput
	}
	out := make([]int64, n)
	base, extra := total/int64(n), total%int64(n)
	for i := range out {
		out[i] = base
		if int64(i) < extra {
			out[i]++
		}
	}
	return out, nil
}
