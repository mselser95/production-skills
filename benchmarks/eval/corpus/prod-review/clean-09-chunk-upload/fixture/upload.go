// Package upload reassembles a file sent as fixed-size chunks that may arrive
// in any order.
package upload

import (
	"errors"
	"sync"
)

var (
	ErrChunkSize  = errors.New("upload: chunk size must be positive")
	ErrTotal      = errors.New("upload: total must be a non-negative whole number of chunks")
	ErrIndex      = errors.New("upload: chunk index out of range")
	ErrBadLength  = errors.New("upload: chunk has the wrong length")
	ErrDuplicate  = errors.New("upload: chunk already received")
	ErrIncomplete = errors.New("upload: chunks missing")
)

// Assembler collects the chunks of one upload of a known total size.
type Assembler struct {
	mu    sync.Mutex
	chunk int
	total int64
	count int64
	parts map[int][]byte
}

// New expects total bytes sent in chunks of chunkSize bytes.
func New(total int64, chunkSize int) (*Assembler, error) {
	if chunkSize <= 0 {
		return nil, ErrChunkSize
	}
	if total < 0 || total%int64(chunkSize) != 0 {
		return nil, ErrTotal
	}
	return &Assembler{
		chunk: chunkSize,
		total: total,
		count: total / int64(chunkSize),
		parts: make(map[int][]byte),
	}, nil
}

// Add stores chunk number idx. The data is copied.
func (a *Assembler) Add(idx int, data []byte) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	if idx < 0 || int64(idx) >= a.count {
		return ErrIndex
	}
	if len(data) != a.chunk {
		return ErrBadLength
	}
	if _, ok := a.parts[idx]; ok {
		return ErrDuplicate
	}
	a.parts[idx] = append([]byte(nil), data...)
	return nil
}

// Complete reports whether every chunk has arrived.
func (a *Assembler) Complete() bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	return int64(len(a.parts)) == a.count
}

// Bytes returns the reassembled upload once every chunk has arrived.
func (a *Assembler) Bytes() ([]byte, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if int64(len(a.parts)) != a.count {
		return nil, ErrIncomplete
	}
	out := make([]byte, 0, a.total)
	for i := int64(0); i < a.count; i++ {
		out = append(out, a.parts[int(i)]...)
	}
	return out, nil
}
