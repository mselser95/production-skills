package catalog

import (
	"errors"
	"testing"
)

func seeded(t *testing.T, ids ...string) *Catalog {
	t.Helper()
	c := &Catalog{}
	for _, id := range ids {
		if err := c.Add(Item{ID: id, Name: "n-" + id}); err != nil {
			t.Fatal(err)
		}
	}
	return c
}

func TestAddKeepsOrderAndRejectsDuplicates(t *testing.T) {
	c := seeded(t, "c", "a", "b")
	got := c.List(0, 10)
	if len(got) != 3 || got[0].ID != "a" || got[2].ID != "c" {
		t.Fatalf("List = %+v", got)
	}
	if err := c.Add(Item{ID: "b"}); !errors.Is(err, ErrDuplicate) {
		t.Fatalf("err = %v", err)
	}
}

func TestListWindow(t *testing.T) {
	c := seeded(t, "a", "b", "c", "d")
	if got := c.List(1, 2); len(got) != 2 || got[0].ID != "b" {
		t.Fatalf("List = %+v", got)
	}
	if got := c.List(9, 2); got != nil {
		t.Fatalf("List past end = %+v", got)
	}
}
