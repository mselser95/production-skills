package batch

import (
	"reflect"
	"testing"
)

func TestFlushAtMax(t *testing.T) {
	var got [][]string
	b := New(2, func(items []string) error {
		got = append(got, append([]string(nil), items...))
		return nil
	})
	for _, s := range []string{"a", "b", "c"} {
		if err := b.Add(s); err != nil {
			t.Fatal(err)
		}
	}
	if want := [][]string{{"a", "b"}}; !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	if b.Pending() != 1 {
		t.Fatalf("pending = %d, want 1", b.Pending())
	}
	if err := b.Flush(); err != nil || b.Pending() != 0 {
		t.Fatalf("flush: err=%v pending=%d", err, b.Pending())
	}
}

func TestFlushEmpty(t *testing.T) {
	calls := 0
	b := New(3, func([]string) error { calls++; return nil })
	if err := b.Flush(); err != nil || calls != 0 {
		t.Fatalf("err=%v calls=%d", err, calls)
	}
}
