package ledger

import (
	"errors"
	"sync"
)

// ErrNotFound is returned when an account does not exist.
var ErrNotFound = errors.New("account not found")

// Store persists account balances in integer cents.
type Store interface {
	Get(id string) (int64, error)
	Put(id string, cents int64) error
}

// MemStore is an in-memory Store.
type MemStore struct {
	mu   sync.Mutex
	bals map[string]int64
}

// NewMemStore returns a store seeded with the given balances.
func NewMemStore(initial map[string]int64) *MemStore {
	m := &MemStore{bals: make(map[string]int64, len(initial))}
	for k, v := range initial {
		m.bals[k] = v
	}
	return m
}

// Get returns the balance of id.
func (m *MemStore) Get(id string) (int64, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	b, ok := m.bals[id]
	if !ok {
		return 0, ErrNotFound
	}
	return b, nil
}

// Put overwrites the balance of an existing account.
func (m *MemStore) Put(id string, cents int64) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.bals[id]; !ok {
		return ErrNotFound
	}
	m.bals[id] = cents
	return nil
}
