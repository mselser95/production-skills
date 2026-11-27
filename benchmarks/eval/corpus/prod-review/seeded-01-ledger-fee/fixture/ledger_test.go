package ledger

import (
	"errors"
	"testing"
)

func TestTransfer(t *testing.T) {
	s := NewMemStore(map[string]int64{"a": 1000, "b": 50})
	l := New(s)
	if err := l.Transfer("a", "b", 300); err != nil {
		t.Fatal(err)
	}
	if got, _ := l.Balance("a"); got != 700 {
		t.Fatalf("a = %d, want 700", got)
	}
	if got, _ := l.Balance("b"); got != 350 {
		t.Fatalf("b = %d, want 350", got)
	}
}

func TestTransferRejects(t *testing.T) {
	l := New(NewMemStore(map[string]int64{"a": 100, "b": 0}))
	if err := l.Transfer("a", "b", 101); !errors.Is(err, ErrInsufficient) {
		t.Fatalf("err = %v, want ErrInsufficient", err)
	}
	if err := l.Transfer("a", "a", 1); !errors.Is(err, ErrInvalid) {
		t.Fatalf("err = %v, want ErrInvalid", err)
	}
	if err := l.Transfer("a", "zz", 1); !errors.Is(err, ErrNotFound) {
		t.Fatalf("err = %v, want ErrNotFound", err)
	}
}
