package auditlog

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestAppendAndClose(t *testing.T) {
	var buf bytes.Buffer
	l := New(&buf)
	for _, e := range []string{"login alice", "grant bob admin"} {
		if err := l.Append(e); err != nil {
			t.Fatal(err)
		}
	}
	if err := l.Close(); err != nil {
		t.Fatal(err)
	}
	if got, want := buf.String(), "1 login alice\n2 grant bob admin\n"; got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
	if err := l.Append("late"); !errors.Is(err, ErrClosed) {
		t.Fatalf("append after close: %v", err)
	}
}

func TestRejectsLineBreak(t *testing.T) {
	var buf bytes.Buffer
	l := New(&buf)
	if err := l.Append("a\nb"); !errors.Is(err, ErrInvalid) {
		t.Fatalf("got %v", err)
	}
}

func TestOpenFileAppends(t *testing.T) {
	p := filepath.Join(t.TempDir(), "audit.log")
	for i := 0; i < 2; i++ {
		l, err := OpenFile(p)
		if err != nil {
			t.Fatal(err)
		}
		if err := l.Append("event"); err != nil {
			t.Fatal(err)
		}
		if err := l.Close(); err != nil {
			t.Fatal(err)
		}
	}
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	if got, want := string(b), "1 event\n1 event\n"; got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}
