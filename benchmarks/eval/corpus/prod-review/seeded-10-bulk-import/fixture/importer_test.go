package bulkimport

import (
	"context"
	"strings"
	"testing"
)

type memStore struct{ got []Record }

func (m *memStore) Put(_ context.Context, rec Record) error {
	m.got = append(m.got, rec)
	return nil
}

func TestImportStoresValidRows(t *testing.T) {
	in := `{"id":"a","name":"widget","qty":2}
{"id":"","name":"bad","qty":1}
{"id":"b","name":"gadget","qty":5}
`
	st := &memStore{}
	res, err := Import(context.Background(), strings.NewReader(in), st)
	if err != nil {
		t.Fatal(err)
	}
	if res.Stored != 2 || res.Rejected != 1 || len(st.got) != 2 {
		t.Fatalf("res=%+v stored=%d", res, len(st.got))
	}
}

func TestParseRejects(t *testing.T) {
	for _, line := range []string{`not json`, `{"id":"a","name":"n","qty":0}`, `{"id":"a","name":" ","qty":1}`} {
		if _, err := Parse([]byte(line)); err == nil {
			t.Fatalf("Parse(%q) accepted", line)
		}
	}
}
