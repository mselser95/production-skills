// Package eventlog is the durable, append-only log this service's aggregate
// is rebuilt from, plus the snapshots that keep that rebuild BOUNDED.
//
// Recovery is the "rebuild from the log on restart" mechanism: the
// composition root (cmd/<SERVICE>) calls Recover, which loads the newest
// valid snapshot and folds only the events recorded after it. A crash
// between "event appended" and "in-memory state updated" loses nothing,
// because the log entry alone is enough to reconstruct the state.
//
// # Why snapshots live INSIDE the log
//
// The obvious design is a separate snapshot file beside the log. It is also
// unfixably racy. Compaction has to replace two files -- the truncated log
// and the snapshot describing what it subsumes -- and there is no ordering
// of two renames that survives a crash between them:
//
//	log first      -> the log is truncated while the snapshot still claims
//	                  to subsume records that are no longer there, so boot
//	                  skips past real history. Silent data loss.
//	snapshot first -> the snapshot claims to subsume nothing while the log
//	                  still holds everything, so boot folds the subsumed
//	                  events on top of a state that already contains them.
//	                  Silent double-apply.
//
// Putting the snapshot in the log as another record kind collapses that to
// ONE atomic rename. Either the old log survives (full history, correct) or
// the new one does (snapshot + tail, correct). There is no third outcome,
// so there is no crash window to reason about.
//
// # Format
//
// One JSON object per line (JSONL), flushed and fsynced on every Append --
// durability over throughput, appropriate for a log where a lost write is a
// lost unit of money, not a lost metric sample. Every line carries a
// schema_version so a future incompatible change is detected instead of
// silently misparsed, and a `kind` discriminating an event record from a
// snapshot record. Version 1 records predate `kind` and are read as events,
// which is what makes an existing production log still recoverable after
// this upgrade.
package eventlog

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sync"

	"github.com/<OWNER>/<SERVICE>/internal/domain"
)

// SchemaVersion is the schema this build WRITES. Bump it, and extend
// SupportedSchemaVersions, on any incompatible change to record's shape.
const SchemaVersion = 2

// SupportedSchemaVersions is every schema this build can READ. Writing one
// version while reading several is what expand/contract means here: a build
// that stopped reading v1 would silently refuse to recover a log written by
// the build it is replacing, which is an outage caused by an upgrade.
var SupportedSchemaVersions = []int{1, 2}

// DefaultSnapshotEvery is how many appended events the composition root
// lets accumulate before taking a snapshot.
//
// It is a constant rather than configuration on purpose: it trades boot
// time against steady-state write amplification, and neither end of that
// trade is a per-deployment decision at this scale. A service whose state
// is expensive to serialize should raise it; one whose boot-time SLO is
// tight should lower it. Both are code changes with a reason, not a knob
// somebody turns during an incident.
const DefaultSnapshotEvery = 1000

// recordKind discriminates the two things a line can be.
type recordKind string

const (
	kindEvent    recordKind = "event"
	kindSnapshot recordKind = "snapshot"
)

// record is the on-disk JSONL shape. Field names are the wire contract --
// renaming one is a breaking schema change (see the golden fixtures and the
// compatibility test).
//
// The event and snapshot fields share one struct rather than living in two
// types because a JSONL reader has to decide what a line IS before it can
// know which type to decode into. One struct with a discriminator is the
// honest shape of that.
type record struct {
	SchemaVersion int        `json:"schema_version"`
	Kind          recordKind `json:"kind,omitempty"`

	// event fields
	ID     string `json:"id,omitempty"`
	Type   string `json:"type,omitempty"`
	Amount string `json:"amount,omitempty"`

	// snapshot field: the folded domain.State, verbatim.
	State json.RawMessage `json:"state,omitempty"`
}

// kindOf reports what a decoded record is, defaulting to an event so that
// v1 records -- which predate the discriminator -- read correctly.
func (r record) kindOf() recordKind {
	if r.Kind == "" {
		return kindEvent
	}
	return r.Kind
}

// Log is the append-only durable event log. Safe for concurrent use: writes
// are serialized by mu, and every write is followed by Sync before Append
// returns.
type Log struct {
	mu   sync.Mutex
	path string
	file *os.File
	// sinceSnapshot counts events appended since the last snapshot, so the
	// composition root can decide when the replay tail has grown long
	// enough to be worth collapsing. Kept here rather than in the caller
	// because the log is the only thing that sees every append.
	sinceSnapshot int
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

// Close closes the underlying file and marks the log unwritable.
//
// Clearing the handle is what makes Close idempotent AND what makes
// Writable honest: healthhttp's readiness gate reads Writable, so a Log that
// kept a non-nil handle after Close would report the durable log writable
// while the process was shutting down -- readiness saying yes to traffic it
// can no longer journal. Shutdown paths are also not reliably exactly-once,
// so a second Close must be a no-op rather than an error.
func (l *Log) Close() error {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.file == nil {
		return nil
	}
	err := l.file.Close()
	l.file = nil
	return err
}

// Append durably records event, returning once the write has been synced to
// stable storage. Satisfies internal/app.EventJournal structurally (no
// import of internal/platform by internal/app -- see that package's port
// doc).
func (l *Log) Append(event domain.Event) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	if err := l.writeLocked(record{
		SchemaVersion: SchemaVersion,
		Kind:          kindEvent,
		ID:            event.ID,
		Type:          string(event.Type),
		Amount:        event.Amount,
	}); err != nil {
		return err
	}
	l.sinceSnapshot++
	return nil
}

// AppendsSinceSnapshot reports how many events have been appended since the
// last snapshot -- the length of the tail a boot would have to replay right
// now. The composition root polls this to decide when to snapshot.
//
// It counts appends made by THIS process only: a freshly opened log reports
// zero even if the file already holds a long un-snapshotted tail. That is
// deliberate and conservative for a scaffold -- the alternative is scanning
// the whole file at open, which is the very cost snapshots exist to avoid --
// and Recover's own stats report the real tail length at boot, which is where
// a too-long tail actually shows up.
func (l *Log) AppendsSinceSnapshot() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.sinceSnapshot
}

// Snapshot durably records the folded state, so a later Recover can start
// from here instead of from genesis.
//
// It is an ordinary append: the snapshot becomes the newest record, and
// every event already in the log before it is subsumed by it. Nothing is
// deleted -- that is Compact's job, deliberately separate, because taking a
// snapshot must never be the operation that can lose history.
func (l *Log) Snapshot(state domain.State) error {
	raw, err := encodeState(state)
	if err != nil {
		return err
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if err := l.writeLocked(record{
		SchemaVersion: SchemaVersion,
		Kind:          kindSnapshot,
		State:         raw,
	}); err != nil {
		return err
	}
	l.sinceSnapshot = 0
	return nil
}

// writeLocked marshals and durably appends one record. Caller holds mu.
func (l *Log) writeLocked(rec record) error {
	if l.file == nil {
		return fmt.Errorf("eventlog: log is closed")
	}
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

// encodeState serializes a domain.State for a snapshot record, and VERIFIES
// the result round-trips before returning it.
//
// The round-trip check is not paranoia. This mechanism is generic over
// whatever domain.State a scaffolded repo defines, and a State carrying an
// unexported field, a channel, or a map with non-string keys marshals to
// something that silently loses data -- producing a snapshot that restores a
// WRONG state, at the one moment nobody is watching. Marshalling three times
// costs nothing at snapshot cadence and turns that into a loud error at the
// moment it happens. TestSnapshot_DomainStateRoundTrips is the same check as
// a standing fitness function on the domain.
func encodeState(state domain.State) (json.RawMessage, error) {
	raw, err := json.Marshal(state)
	if err != nil {
		return nil, fmt.Errorf("eventlog: marshal state: %w", err)
	}
	var back domain.State
	if err := json.Unmarshal(raw, &back); err != nil {
		return nil, fmt.Errorf("eventlog: snapshot state does not decode: %w", err)
	}
	again, err := json.Marshal(back)
	if err != nil {
		return nil, fmt.Errorf("eventlog: re-marshal state: %w", err)
	}
	if !bytes.Equal(raw, again) {
		return nil, fmt.Errorf(
			"eventlog: domain.State does not round-trip through JSON (%s != %s) -- "+
				"a snapshot would restore a state different from the one taken; give State "+
				"exported, JSON-representable fields or a custom marshaler", raw, again)
	}
	return raw, nil
}

// Writable reports whether this log's underlying file is currently open for
// writing -- the readiness gate healthhttp checks (see
// internal/adapter/in/healthhttp).
func (l *Log) Writable() bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.file != nil
}

// RecoverStats describes what a Recover actually did. Returned rather than
// logged from inside so the composition root decides how loud to be, and so
// a test can assert that snapshots are DOING something -- a snapshot that is
// written but never used on boot is decoration, and EventsReplayed is what
// catches it.
type RecoverStats struct {
	// SnapshotFound is true when recovery started from a snapshot rather
	// than from genesis.
	SnapshotFound bool
	// EventsReplayed counts the events folded on top of the base state.
	// With a snapshot this is only the tail; without one it is the whole
	// history.
	EventsReplayed int
	// RecordsScanned counts every line read, snapshots included.
	RecordsScanned int
	// SnapshotsRejected counts snapshot records that failed to decode and
	// were skipped in favour of an older snapshot or a full replay. Any
	// value above zero means recovery silently cost more than it should
	// have, so the composition root logs it loudly rather than shrugging.
	SnapshotsRejected int
}

// Recover reconstructs the state to boot from: the newest VALID snapshot,
// with every event recorded after it folded on top.
//
// A snapshot record that fails to decode is SKIPPED, not fatal -- recovery
// falls back to an older snapshot or, failing that, to a full replay from
// genesis, and reports how many it rejected. Refusing to boot because a
// performance optimization is corrupt would turn a slow start into an
// outage. A corrupt EVENT record is still fatal, because that is history,
// and quietly continuing past it is how a ledger loses money.
func Recover(path string) (domain.State, RecoverStats, error) {
	var stats RecoverStats

	records, err := readRecords(path)
	if err != nil {
		return domain.State{}, stats, err
	}
	stats.RecordsScanned = len(records)

	// Walk backwards to the newest snapshot that actually decodes.
	base := domain.NewState()
	start := 0
	for i := len(records) - 1; i >= 0; i-- {
		if records[i].kindOf() != kindSnapshot {
			continue
		}
		var state domain.State
		if err := json.Unmarshal(records[i].State, &state); err != nil {
			stats.SnapshotsRejected++
			continue
		}
		base = state
		start = i + 1
		stats.SnapshotFound = true
		break
	}

	state := base
	for _, rec := range records[start:] {
		if rec.kindOf() != kindEvent {
			continue
		}
		state, _ = domain.Apply(state, eventFrom(rec))
		stats.EventsReplayed++
	}
	return state, stats, nil
}

// CompactStats describes what a Compact did.
type CompactStats struct {
	// RecordsBefore and RecordsAfter bracket the reclaimed history.
	RecordsBefore int
	RecordsAfter  int
	// Compacted is false when there was nothing to do -- no snapshot to
	// compact against. Reported rather than treated as an error, because
	// "nothing to reclaim yet" is the normal state of a young log.
	Compacted bool
}

// Compact rewrites the log as [newest snapshot] + [events after it],
// discarding the history that snapshot already subsumes. Storage stops
// growing with total history and starts tracking history-since-snapshot.
//
// The rewrite is ONE atomic rename, which is what makes it crash-safe: the
// old log survives intact until the instant the new one replaces it, and
// both files are independently correct to recover from. See the package doc
// for why a separate snapshot file cannot achieve this.
//
// Compaction is a no-op unless the log holds a decodable snapshot -- there
// is nothing to subsume history against otherwise, and truncating without
// one would simply delete it.
func (l *Log) Compact() (CompactStats, error) {
	l.mu.Lock()
	defer l.mu.Unlock()

	var stats CompactStats
	records, err := readRecords(l.path)
	if err != nil {
		return stats, err
	}
	stats.RecordsBefore = len(records)

	keepFrom := -1
	for i := len(records) - 1; i >= 0; i-- {
		if records[i].kindOf() != kindSnapshot {
			continue
		}
		var probe domain.State
		if err := json.Unmarshal(records[i].State, &probe); err != nil {
			continue // an undecodable snapshot subsumes nothing
		}
		keepFrom = i
		break
	}
	if keepFrom < 0 {
		stats.RecordsAfter = stats.RecordsBefore
		return stats, nil
	}

	kept := records[keepFrom:]
	tmp := l.path + ".compact"
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o644)
	if err != nil {
		return stats, fmt.Errorf("eventlog: compact open %s: %w", tmp, err)
	}
	for _, rec := range kept {
		line, err := json.Marshal(rec)
		if err != nil {
			_ = f.Close()
			_ = os.Remove(tmp)
			return stats, fmt.Errorf("eventlog: compact marshal: %w", err)
		}
		if _, err := f.Write(append(line, '\n')); err != nil {
			_ = f.Close()
			_ = os.Remove(tmp)
			return stats, fmt.Errorf("eventlog: compact write: %w", err)
		}
	}
	// The replacement must be on stable storage BEFORE it replaces
	// anything. Renaming an unsynced file over the only copy of the history
	// is how compaction turns a crash into data loss.
	if err := f.Sync(); err != nil {
		_ = f.Close()
		_ = os.Remove(tmp)
		return stats, fmt.Errorf("eventlog: compact sync: %w", err)
	}
	if err := f.Close(); err != nil {
		_ = os.Remove(tmp)
		return stats, fmt.Errorf("eventlog: compact close: %w", err)
	}
	if err := os.Rename(tmp, l.path); err != nil {
		_ = os.Remove(tmp)
		return stats, fmt.Errorf("eventlog: compact rename: %w", err)
	}
	// fsync the DIRECTORY so the rename itself is durable. Without this the
	// rename can be lost by a crash even though both files were synced,
	// leaving the pre-compaction log -- correct, but the reclaim silently
	// did not happen.
	if dir, err := os.Open(filepath.Dir(l.path)); err == nil {
		_ = dir.Sync()
		_ = dir.Close()
	}

	// The old file descriptor now points at an unlinked inode; appends
	// through it would vanish. Reopen against the new file.
	if l.file != nil {
		_ = l.file.Close()
	}
	reopened, err := os.OpenFile(l.path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		l.file = nil
		return stats, fmt.Errorf("eventlog: compact reopen %s: %w", l.path, err)
	}
	l.file = reopened

	stats.RecordsAfter = len(kept)
	stats.Compacted = true
	l.sinceSnapshot = len(kept) - 1 // everything kept after the snapshot record
	return stats, nil
}

// readRecords reads every line of the log into decoded records.
func readRecords(path string) ([]record, error) {
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("eventlog: open %s for replay: %w", path, err)
	}
	defer func() { _ = f.Close() }()

	var records []record
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	lineNo := 0
	for scanner.Scan() {
		lineNo++
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}
		rec, err := decodeLine(line)
		if err != nil {
			return nil, fmt.Errorf("eventlog: replay %s line %d: %w", path, lineNo, err)
		}
		records = append(records, rec)
	}
	if err := scanner.Err(); err != nil && err != io.EOF {
		return nil, fmt.Errorf("eventlog: scan %s: %w", path, err)
	}
	return records, nil
}

// decodeLine decodes one JSONL line into a record, rejecting a schema this
// build cannot read.
func decodeLine(line []byte) (record, error) {
	var rec record
	if err := json.Unmarshal(line, &rec); err != nil {
		return record{}, fmt.Errorf("decode: %w", err)
	}
	if !schemaSupported(rec.SchemaVersion) {
		return record{}, ErrUnknownSchemaVersion
	}
	return rec, nil
}

// decodeRecord decodes one line as an EVENT. It is the package's decode
// boundary for untrusted bytes -- FuzzDecodeRecord drives it directly with
// whatever a partial write, disk corruption or a hand-edited file might
// leave behind, and it must never panic.
func decodeRecord(line []byte) (domain.Event, error) {
	rec, err := decodeLine(line)
	if err != nil {
		return domain.Event{}, err
	}
	if rec.kindOf() == kindSnapshot {
		return domain.Event{}, ErrSnapshotInLog
	}
	return eventFrom(rec), nil
}

func schemaSupported(v int) bool {
	for _, s := range SupportedSchemaVersions {
		if s == v {
			return true
		}
	}
	return false
}

// ErrUnknownSchemaVersion is returned for a schema_version this build does
// not know how to read. Failing loudly here is deliberate: a silent
// best-effort parse of a record shape a future migration changed is how a
// ledger quietly loses history.
var ErrUnknownSchemaVersion = fmt.Errorf("eventlog: unknown schema_version (supported: %v)", SupportedSchemaVersions)

// ErrSnapshotInLog is returned by Replay when the log contains a snapshot
// record. Replay reports only EVENTS, so on a compacted log its output is
// the tail rather than the history -- and folding that tail from genesis
// silently reconstructs a wrong state. Refusing is the only safe answer;
// the caller wants Recover.
var ErrSnapshotInLog = fmt.Errorf("eventlog: log contains a snapshot; use Recover, not Replay+Rebuild")

// Replay reads every EVENT previously Appended, in order. It does NOT fold
// them through domain.Apply -- that is Rebuild's job -- and it does not know
// about snapshots.
//
// It deliberately REFUSES a log containing a snapshot rather than returning
// the events it can see. On a compacted log those events are only the tail,
// and a caller doing Rebuild(Replay(path)) would get a confidently wrong
// state with no error anywhere. Recover is the snapshot-aware read.
func Replay(path string) ([]domain.Event, error) {
	records, err := readRecords(path)
	if err != nil {
		return nil, err
	}
	events := make([]domain.Event, 0, len(records))
	for _, rec := range records {
		if rec.kindOf() == kindSnapshot {
			return nil, ErrSnapshotInLog
		}
		events = append(events, eventFrom(rec))
	}
	return events, nil
}

func eventFrom(rec record) domain.Event {
	return domain.Event{ID: rec.ID, Type: domain.EventType(rec.Type), Amount: rec.Amount}
}

// Rebuild folds a slice of events through domain.Apply in order, starting
// from domain.NewState(), and returns the resulting State.
func Rebuild(events []domain.Event) domain.State {
	return RebuildFrom(domain.NewState(), events)
}

// RebuildFrom folds events onto an existing base state -- the operation
// Recover performs on top of a snapshot. Exported alongside Rebuild so the
// snapshot-aware and genesis paths are visibly the same fold, differing
// only in where they start.
func RebuildFrom(base domain.State, events []domain.Event) domain.State {
	state := base
	for _, event := range events {
		state, _ = domain.Apply(state, event)
	}
	return state
}

// RebuildFromVisit folds events onto base exactly as RebuildFrom does, and
// additionally hands each event's effects to visit as it goes.
//
// It exists so the boot-time outbox reconstruction can see the effects that
// RebuildFrom discards, WITHOUT a second pass. A second pass would be subtly
// wrong rather than merely wasteful: it would re-apply every event against a
// state it built independently, so the caller would hold effects derived from
// one fold and a state derived from another. They would agree today, because
// domain.Apply is deterministic -- and they would stop agreeing the first time
// anyone made Apply depend on anything the two passes could see differently.
//
// visit is called once per event, in log order, with the effects that event
// produced. It may be nil, which makes this exactly RebuildFrom.
func RebuildFromVisit(base domain.State, events []domain.Event, visit func(domain.Event, []domain.Effect)) domain.State {
	state := base
	for _, event := range events {
		var effects []domain.Effect
		state, effects = domain.Apply(state, event)
		if visit != nil {
			visit(event, effects)
		}
	}
	return state
}
