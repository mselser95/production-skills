package quota

import (
	"sync"
	"time"
)

type entry struct {
	at time.Time
	n  int64
}

// Meter counts usage per tenant against one limit.
type Meter struct {
	mu     sync.Mutex
	now    func() time.Time
	limit  int64
	window time.Duration
	used   map[string][]entry
}

// New returns a meter that admits at most limit units per tenant per window.
func New(limit int64, window time.Duration, now func() time.Time) (*Meter, error) {
	if limit < 0 || window <= 0 || now == nil {
		return nil, ErrConfig
	}
	return &Meter{now: now, limit: limit, window: window, used: make(map[string][]entry)}, nil
}

// Charge records n units for tenant, or returns ErrLimit and records nothing.
func (m *Meter) Charge(tenant string, n int64) error {
	if n <= 0 {
		return ErrAmount
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	var used int64
	for _, e := range m.used[tenant] {
		used += e.n
	}
	if used+n > m.limit {
		return ErrLimit
	}
	m.used[tenant] = append(m.used[tenant], entry{at: m.now(), n: n})
	return nil
}
