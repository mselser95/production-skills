package bulkimport

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
)

// Record is one row of the import stream.
type Record struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Qty  int    `json:"qty"`
}

// Parse decodes and validates one JSONL line.
func Parse(line []byte) (Record, error) {
	var rec Record
	if err := json.Unmarshal(line, &rec); err != nil {
		return Record{}, fmt.Errorf("decode: %w", err)
	}
	rec.ID = strings.TrimSpace(rec.ID)
	rec.Name = strings.TrimSpace(rec.Name)
	if rec.ID == "" {
		return Record{}, errors.New("missing id")
	}
	if rec.Name == "" {
		return Record{}, errors.New("missing name")
	}
	if rec.Qty < 1 {
		return Record{}, errors.New("qty must be positive")
	}
	return rec, nil
}
