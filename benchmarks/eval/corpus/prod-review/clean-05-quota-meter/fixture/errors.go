package quota

import "errors"

var (
	// ErrAmount is returned for a charge that is zero or negative.
	ErrAmount = errors.New("quota: amount must be positive")
	// ErrLimit is returned when a charge does not fit in what is left.
	ErrLimit = errors.New("quota: limit exceeded")
	// ErrConfig is returned by New for a negative limit or a non-positive window.
	ErrConfig = errors.New("quota: invalid configuration")
)
