package lease

import (
	"errors"
	"sync"
	"time"
)

// Errors returned by Keeper.
var (
	ErrTTL     = errors.New("lease: ttl must be positive")
	ErrHeld    = errors.New("lease: held by another owner")
	ErrNotHeld = errors.New("lease: not held by this owner")
)

// Keeper hands out named leases that last ttl on an injected clock.
type Keeper struct {
	mu     sync.Mutex
	clock  Clock
	ttl    time.Duration
	leases map[string]entry
}

type entry struct {
	owner   string
	expires time.Time
}

// NewKeeper returns a Keeper whose leases last ttl on the given clock.
func NewKeeper(c Clock, ttl time.Duration) (*Keeper, error) {
	if ttl <= 0 {
		return nil, ErrTTL
	}
	return &Keeper{clock: c, ttl: ttl, leases: map[string]entry{}}, nil
}
