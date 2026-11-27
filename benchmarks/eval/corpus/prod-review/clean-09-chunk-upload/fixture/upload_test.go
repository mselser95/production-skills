package upload

import (
	"bytes"
	"errors"
	"testing"
)

func TestOutOfOrder(t *testing.T) {
	a, err := New(6, 2)
	if err != nil {
		t.Fatal(err)
	}
	for _, i := range []int{2, 0, 1} {
		if a.Complete() {
			t.Fatal("complete too early")
		}
		if err := a.Add(i, []byte{byte(2 * i), byte(2*i + 1)}); err != nil {
			t.Fatal(err)
		}
	}
	got, err := a.Bytes()
	if err != nil || !bytes.Equal(got, []byte{0, 1, 2, 3, 4, 5}) {
		t.Fatalf("got %v, %v", got, err)
	}
}

func TestIncompleteAndDuplicate(t *testing.T) {
	a, _ := New(4, 2)
	if err := a.Add(0, []byte("ab")); err != nil {
		t.Fatal(err)
	}
	if err := a.Add(0, []byte("ab")); !errors.Is(err, ErrDuplicate) {
		t.Fatalf("got %v", err)
	}
	if _, err := a.Bytes(); !errors.Is(err, ErrIncomplete) {
		t.Fatalf("got %v", err)
	}
}
