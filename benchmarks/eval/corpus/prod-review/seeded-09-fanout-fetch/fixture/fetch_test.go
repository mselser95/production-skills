package fanout

import (
	"context"
	"errors"
	"testing"
)

func fixed(items ...Item) Backend {
	return func(context.Context, string) ([]Item, error) { return items, nil }
}

func TestMergeKeepsBestScore(t *testing.T) {
	f := New(1, fixed(Item{"a", 1}, Item{"b", 5}), fixed(Item{"a", 9}))
	got, err := f.Fetch(context.Background(), "q")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || got[0] != (Item{"a", 9}) || got[1] != (Item{"b", 5}) {
		t.Fatalf("got %v", got)
	}
}

func TestOneFailureIsSkipped(t *testing.T) {
	bad := func(context.Context, string) ([]Item, error) { return nil, errors.New("down") }
	got, err := New(2, bad, fixed(Item{"a", 1})).Fetch(context.Background(), "q")
	if err != nil || len(got) != 1 {
		t.Fatalf("got %v, %v", got, err)
	}
}

func TestAllFailReturnsError(t *testing.T) {
	bad := func(context.Context, string) ([]Item, error) { return nil, errors.New("down") }
	if _, err := New(2, bad, bad).Fetch(context.Background(), "q"); err == nil {
		t.Fatal("want error")
	}
}

func TestRetriesUntilSuccess(t *testing.T) {
	n := 0
	flaky := func(context.Context, string) ([]Item, error) {
		n++
		if n < 3 {
			return nil, errors.New("flaky")
		}
		return []Item{{"a", 1}}, nil
	}
	got, err := New(3, flaky).Fetch(context.Background(), "q")
	if err != nil || len(got) != 1 {
		t.Fatalf("got %v, %v", got, err)
	}
}
