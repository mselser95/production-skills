package split

import "testing"

func TestEven(t *testing.T) {
	got, err := Even(1000, 3)
	if err != nil {
		t.Fatal(err)
	}
	want := []int64{334, 333, 333}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("Even = %v, want %v", got, want)
		}
	}
	if _, err := Even(1, 0); err == nil {
		t.Fatal("n=0 must fail")
	}
}
