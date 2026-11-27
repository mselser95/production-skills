package ledger

import (
	"errors"
	"fmt"
)

var (
	// ErrInvalid is returned for a non-positive amount or a self transfer.
	ErrInvalid = errors.New("invalid transfer")
	// ErrInsufficient is returned when the source cannot cover the amount.
	ErrInsufficient = errors.New("insufficient funds")
)

// Ledger moves money between accounts held in a Store.
type Ledger struct {
	store Store
}

// New returns a Ledger over s.
func New(s Store) *Ledger { return &Ledger{store: s} }

// Balance returns the balance of id in cents.
func (l *Ledger) Balance(id string) (int64, error) { return l.store.Get(id) }

// Transfer moves cents from one account to another.
func (l *Ledger) Transfer(from, to string, cents int64) error {
	if cents <= 0 || from == to {
		return ErrInvalid
	}
	fb, err := l.store.Get(from)
	if err != nil {
		return fmt.Errorf("read %s: %w", from, err)
	}
	tb, err := l.store.Get(to)
	if err != nil {
		return fmt.Errorf("read %s: %w", to, err)
	}
	if fb < cents {
		return ErrInsufficient
	}
	if err := l.store.Put(from, fb-cents); err != nil {
		return fmt.Errorf("debit %s: %w", from, err)
	}
	if err := l.store.Put(to, tb+cents); err != nil {
		return fmt.Errorf("credit %s: %w", to, err)
	}
	return nil
}
