package auditlog

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"strings"
	"sync"
)

// ErrClosed is returned by Append and Flush after Close.
var ErrClosed = errors.New("auditlog: closed")

// ErrInvalid is returned for an event that would break the one-line-per-entry
// format.
var ErrInvalid = errors.New("auditlog: event contains a line break")

// Log is an append-only audit log: one numbered line per event.
type Log struct {
	mu     sync.Mutex
	dst    io.Writer
	w      *bufio.Writer
	seq    uint64
	closed bool
}

// New returns a Log that writes to dst.
func New(dst io.Writer) *Log {
	return &Log{dst: dst, w: bufio.NewWriter(dst)}
}

// Append writes "<seq> <event>\n". Sequence numbers start at 1 and only
// advance for an entry that was accepted into the buffer.
func (l *Log) Append(event string) error {
	if strings.ContainsAny(event, "\r\n") {
		return ErrInvalid
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.closed {
		return ErrClosed
	}
	if _, err := fmt.Fprintf(l.w, "%d %s\n", l.seq+1, event); err != nil {
		return err
	}
	l.seq++
	return nil
}

// Flush pushes buffered entries to the destination.
func (l *Log) Flush() error {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.closed {
		return ErrClosed
	}
	return l.w.Flush()
}

// Close flushes buffered entries and stops accepting new ones.
func (l *Log) Close() error {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.closed {
		return nil
	}
	l.closed = true
	return l.w.Flush()
}
