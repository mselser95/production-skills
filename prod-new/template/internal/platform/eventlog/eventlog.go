// Package eventlog is the durable, append-only log of domain.Event this
// service's ledger aggregate is rebuilt from. It is the "recovery: rebuild
// from the log on restart" mechanism: the composition root (cmd/<SERVICE>) opens
// the log, Replays it into an internal/domain.State by folding domain.Apply
// over every recorded event in order, and only THEN constructs
// internal/app.Ledger with that state -- a crash between "event appended"
// and "in-memory state updated" loses nothing, because the log entry alone
// is enough to reconstruct the state on the next boot.
//
// Format: one JSON object per line (JSONL), flushed and fsynced on every
// Append -- durability over throughput, appropriate for a ledger where a
// lost write is a lost unit of money, not a lost metric sample.
// schema_version is stamped on every line so a future incompatible change
// to the event shape can be detected instead of silently misparsed (see
// TestLog_RejectsAnUnknownSchemaVersion and the wire-compatibility golden
// test in eventlog_wire_test.go).
package eventlog

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"sync"

	"github.com/<OWNER>/<SERVICE>/internal/domain"
)

// SchemaVersion is the current on-disk record schema. Bump this, and add a
// migration branch to decodeRecord, on any incompatible change to record's
// shape.
const SchemaVersion = 1

// record is the on-disk JSONL shape. Field names are the wire contract --
// renaming one is a breaking schema change (see the compatibility/golden
// test).
type record struct {
	SchemaVersion int    `json:"schema_version"`
	ID            string `json:"id"`
	Type          string `json:"type"`
	Amount        string `json:"amount"`
}

// Log is the append-only durable event log. Safe for concurrent use: writes
// are serialized by mu, and every write is followed by Sync before Append
// returns.
type Log struct {
	mu   sync.Mutex
	path string
	file *os.File
}

// Open opens (creating if necessary) the log file at path for appending.
// The caller must Close it when done.
func Open(path string) (*Log, error) {
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return nil, fmt.Errorf("eventlog: open %s: %w", path, err)
	}
	return &Log{path: path, file: f}, nil
}

// Close closes the underlying file.
func (l *Log) Close() error {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.file.Close()
}

// Append durably records event, returning once the write has been synced to
// stable storage. Satisfies internal/app.EventJournal structurally (no
// import of internal/platform by internal/app -- see that package's port
// doc).
func (l *Log) Append(event domain.Event) error {
	l.mu.Lock()
	defer l.mu.Unlock()

	rec := record{SchemaVersion: SchemaVersion, ID: event.ID, Type: string(event.Type), Amount: event.Amount}
	line, err := json.Marshal(rec)
	if err != nil {
		return fmt.Errorf("eventlog: marshal: %w", err)
	}
	line = append(line, '\n')
	if _, err := l.file.Write(line); err != nil {
		return fmt.Errorf("eventlog: write: %w", err)
	}
	if err := l.file.Sync(); err != nil {
		return fmt.Errorf("eventlog: sync: %w", err)
	}
	return nil
}

// Writable reports whether this log's underlying file is currently open for
// writing -- the readiness gate healthhttp checks (see
// internal/adapter/in/healthhttp).
func (l *Log) Writable() bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.file != nil
}

// Replay reads every event previously Appended, in order, decoding each
// JSONL line back into a domain.Event. It does NOT fold them through
// domain.Apply itself -- that is the composition root's job (see the
// package doc) -- Replay's only responsibility is durable storage's read
// side.
func Replay(path string) ([]domain.Event, error) {
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("eventlog: open %s for replay: %w", path, err)
	}
	defer func() { _ = f.Close() }()

	var events []domain.Event
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	lineNo := 0
	for scanner.Scan() {
		lineNo++
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}
		event, err := decodeRecord(line)
		if err != nil {
			return nil, fmt.Errorf("eventlog: replay %s line %d: %w", path, lineNo, err)
		}
		events = append(events, event)
	}
	if err := scanner.Err(); err != nil && err != io.EOF {
		return nil, fmt.Errorf("eventlog: scan %s: %w", path, err)
	}
	return events, nil
}

// ErrUnknownSchemaVersion is returned by decodeRecord for a schema_version
// this build does not know how to read. Failing loudly here is deliberate:
// a silent best-effort parse of a record shape a future migration changed
// is how a ledger quietly loses history.
var ErrUnknownSchemaVersion = fmt.Errorf("eventlog: unknown schema_version (want %d)", SchemaVersion)

func decodeRecord(line []byte) (domain.Event, error) {
	var rec record
	if err := json.Unmarshal(line, &rec); err != nil {
		return domain.Event{}, fmt.Errorf("decode: %w", err)
	}
	if rec.SchemaVersion != SchemaVersion {
		return domain.Event{}, ErrUnknownSchemaVersion
	}
	return domain.Event{ID: rec.ID, Type: domain.EventType(rec.Type), Amount: rec.Amount}, nil
}

// Rebuild folds a slice of events through domain.Apply in order, starting
// from domain.NewState(), and returns the resulting State. This is the
// exact operation the composition root performs over Replay's output at
// boot; exported here (rather than only inlined in cmd/<SERVICE>) so it is
// directly unit-testable and reusable by the replay-corpus regression
// harness (regressions/) without either depending on internal/app.
func Rebuild(events []domain.Event) domain.State {
	state := domain.NewState()
	for _, event := range events {
		state, _ = domain.Apply(state, event)
	}
	return state
}
