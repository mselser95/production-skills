// Package bulkimport validates and stores records from a JSONL stream.
package bulkimport

import (
	"bufio"
	"context"
	"fmt"
	"io"
)

// Store persists one record. Put may fail; the record is then not stored.
type Store interface {
	Put(ctx context.Context, rec Record) error
}

// Result summarises one import run.
type Result struct {
	Stored   int // rows written to the store
	Rejected int // rows that failed validation
}

// Import reads JSONL records from r, validates each one and stores the valid
// ones. Invalid rows are counted in Rejected and skipped. A store failure
// stops the import and is returned with its row number.
func Import(ctx context.Context, r io.Reader, s Store) (Result, error) {
	var res Result
	sc := bufio.NewScanner(r)
	row := 0
	for sc.Scan() {
		row++
		if err := ctx.Err(); err != nil {
			return res, err
		}
		rec, err := Parse(sc.Bytes())
		if err != nil {
			res.Rejected++
			continue
		}
		if err := s.Put(ctx, rec); err != nil {
			return res, fmt.Errorf("row %d: %w", row, err)
		}
		res.Stored++
	}
	return res, sc.Err()
}
