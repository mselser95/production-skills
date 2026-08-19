// Package outboxlog is the durable, append-only log the OUTBOX is rebuilt
// from on restart. It is internal/platform/eventlog's discipline applied to
// a second aggregate: one JSON object per line, fsynced on every append,
// schema_version stamped and refused on mismatch, and a decode that fails
// loudly instead of guessing.
//
// It records STATE TRANSITIONS, not current state. Replaying the transitions
// reconstructs the outbox exactly the way replaying eventlog reconstructs
// domain state — one mental model in this repo, not two — and it means a
// crash between two transitions loses at most the last one rather than
// corrupting a rewritten record.
//
// Effect serialization here is a TAGGED encoding, and it is deliberately
// SEPARATE from whatever wire format a consumer of this service parses. The
// two overlap today and sharing one type would be tempting; the reason not
// to is that a field added for a consumer would silently change what a
// restart reconstructs. A stored intent must mean tomorrow exactly what it
// meant when it was written.
package outboxlog

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"sync"

	"github.com/<OWNER>/<SERVICE>/internal/domain"
)

// SchemaVersion is the current on-disk record schema WRITTEN by this build.
// Bump it, and widen SupportedSchemaVersions, on any incompatible change.
const SchemaVersion = 2

// SupportedSchemaVersions is every schema this build can READ. Writing one
// version while reading several is what makes a rolling upgrade safe: a
// build that refused the previous version would discard the pending intents
// of the process it replaced -- losing exactly the effects this log exists
// to protect, at exactly the moment nobody is watching.
var SupportedSchemaVersions = []int{1, 2}

// Entry states, mirroring internal/adapter/out/store's own vocabulary. They
// are duplicated as plain strings rather than imported: internal/platform
// must not import internal/adapter (see
// internal/architecture/boundaries_test.go), and a durable format that moved
// whenever an adapter's Go types were refactored would not be a format.
const (
	StateIntent    = "intent"
	StateDelivered = "delivered"
	StateFailed    = "failed"
	// StateDeadLettered is an entry evicted by a bound (see
	// internal/adapter/out/store.Limits). It is NOT a delivery outcome: the
	// effect was never delivered and may still be deliverable. It exists so
	// an overflowing outbox has somewhere to put an entry that is neither
	// lost nor still consuming the bound.
	StateDeadLettered = "dead_lettered"
)

// Effect kind tags. These strings are the wire contract: renaming one is a
// breaking schema change, which is what the golden fixture test exists to
// catch.
const (
	KindDeposited = "deposited"
	KindWithdrawn = "withdrawn"
)

// EffectEnvelope is the tagged, durable encoding of a routable domain
// effect.
type EffectEnvelope struct {
	Kind    string `json:"kind"`
	EventID string `json:"event_id"`
	Amount  string `json:"amount"`
}

// Record is one state transition of one outbox entry — the on-disk JSONL
// shape. Field names are the wire contract.
type Record struct {
	SchemaVersion  int             `json:"schema_version"`
	EntryID        string          `json:"entry_id"`
	State          string          `json:"state"`
	IdempotencyKey string          `json:"idempotency_key,omitempty"`
	Attempts       int             `json:"attempts,omitempty"`
	Effect         *EffectEnvelope `json:"effect,omitempty"`
	// JournaledAtUnixNano is when the intent was accepted. Added in schema
	// 2 for the age bound: without it, an entry restored at boot is
	// indistinguishable from one journaled a moment ago, so an age bound
	// would reset on every restart and a crash-looping service would never
	// evict anything. Zero on a schema-1 record, which is why age carries
	// an explicit unknown (see Snapshot.AgeKnown).
	JournaledAtUnixNano int64 `json:"journaled_at_unix_nano,omitempty"`
}

// ErrUnencodableEffect is returned for an effect this durable format has no
// tag for. Callers must treat it as a refusal to accept the intent at all:
// an entry that could never be replayed must not be journaled, or the caller
// believes an effect is safe while a restart silently loses it.
var ErrUnencodableEffect = fmt.Errorf("outboxlog: effect has no durable encoding")

// ErrUnknownSchemaVersion is returned by DecodeRecord for a schema_version
// this build cannot read. Failing loudly is deliberate: a best-effort parse
// of a shape a future migration changed is how an outbox quietly loses
// intents.
var ErrUnknownSchemaVersion = fmt.Errorf("outboxlog: unknown schema_version (readable: %v)", SupportedSchemaVersions)

// EncodeEffect renders a routable effect into its durable envelope, or
// ErrUnencodableEffect if this format cannot represent it.
func EncodeEffect(effect domain.Effect) (EffectEnvelope, error) {
	switch v := effect.(type) {
	case domain.EffectDeposited:
		return EffectEnvelope{Kind: KindDeposited, EventID: v.EventID, Amount: v.Amount}, nil
	case domain.EffectWithdrawn:
		return EffectEnvelope{Kind: KindWithdrawn, EventID: v.EventID, Amount: v.Amount}, nil
	default:
		return EffectEnvelope{}, fmt.Errorf("%w: %T", ErrUnencodableEffect, effect)
	}
}

// DecodeEffect rebuilds a domain effect from its durable envelope.
func DecodeEffect(env EffectEnvelope) (domain.Effect, error) {
	switch env.Kind {
	case KindDeposited:
		return domain.EffectDeposited{EventID: env.EventID, Amount: env.Amount}, nil
	case KindWithdrawn:
		return domain.EffectWithdrawn{EventID: env.EventID, Amount: env.Amount}, nil
	default:
		return nil, fmt.Errorf("%w: kind %q", ErrUnencodableEffect, env.Kind)
	}
}

// Log is the append-only durable outbox log. Safe for concurrent use: writes
// are serialized by mu and every write is synced before Append returns.
type Log struct {
	mu   sync.Mutex
	path string
	file *os.File
}

// Open opens (creating if necessary) the log at path for appending.
func Open(path string) (*Log, error) {
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return nil, fmt.Errorf("outboxlog: open %s: %w", path, err)
	}
	return &Log{path: path, file: f}, nil
}

// Close closes the underlying file.
func (l *Log) Close() error {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.file.Close()
}

// Append durably records one state transition, returning once the write has
// been synced to stable storage.
func (l *Log) Append(rec Record) error {
	l.mu.Lock()
	defer l.mu.Unlock()

	rec.SchemaVersion = SchemaVersion
	line, err := json.Marshal(rec)
	if err != nil {
		return fmt.Errorf("outboxlog: marshal: %w", err)
	}
	line = append(line, '\n')
	if _, err := l.file.Write(line); err != nil {
		return fmt.Errorf("outboxlog: write: %w", err)
	}
	// NO TEST GUARDS THIS LINE. Removing the Sync STAYED GREEN under
	// mutation on 2026-08-18: no in-process test can tell fsync from
	// no-fsync, because a normally-exiting process flushes its writes
	// anyway. Proving it needs a killed CONTAINER, not a killed goroutine.
	// See registries/contract-debt.yaml for the owned, expiring entry that
	// tracks the docker-kill test which would close it.
	if err := l.file.Sync(); err != nil {
		return fmt.Errorf("outboxlog: sync: %w", err)
	}
	return nil
}

// Writable reports whether this log is open for writing.
func (l *Log) Writable() bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.file != nil
}

// Replay reads every transition previously appended, in order.
func Replay(path string) ([]Record, error) {
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("outboxlog: open %s for replay: %w", path, err)
	}
	defer func() { _ = f.Close() }()

	var records []Record
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	lineNo := 0
	for scanner.Scan() {
		lineNo++
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}
		rec, err := DecodeRecord(line)
		if err != nil {
			return nil, fmt.Errorf("outboxlog: replay %s line %d: %w", path, lineNo, err)
		}
		records = append(records, rec)
	}
	if err := scanner.Err(); err != nil && err != io.EOF {
		return nil, fmt.Errorf("outboxlog: scan %s: %w", path, err)
	}
	return records, nil
}

// DecodeRecord parses one JSONL line. It is the decode boundary
// FuzzDecodeOutboxRecord drives directly.
func DecodeRecord(line []byte) (Record, error) {
	var rec Record
	if err := json.Unmarshal(line, &rec); err != nil {
		return Record{}, fmt.Errorf("decode: %w", err)
	}
	if !readableSchema(rec.SchemaVersion) {
		return Record{}, ErrUnknownSchemaVersion
	}
	if rec.EntryID == "" {
		return Record{}, fmt.Errorf("outboxlog: record with empty entry_id")
	}
	switch rec.State {
	case StateIntent, StateDelivered, StateFailed, StateDeadLettered:
	default:
		return Record{}, fmt.Errorf("outboxlog: unknown state %q", rec.State)
	}
	return rec, nil
}

func readableSchema(v int) bool {
	for _, ok := range SupportedSchemaVersions {
		if v == ok {
			return true
		}
	}
	return false
}

// Snapshot is one entry's reconstructed current state, the output of folding
// its transitions. It carries only primitive types plus a domain effect, so
// internal/adapter/out/store can build its own Entry from it without this
// package knowing that type exists.
type Snapshot struct {
	EntryID        string
	State          string
	IdempotencyKey string
	Attempts       int
	Effect         domain.Effect
	// JournaledAtUnixNano is when the intent was accepted, or zero when the
	// record predates schema 2.
	JournaledAtUnixNano int64
	// AgeKnown is false for an entry replayed from a schema-1 record, whose
	// journaling time was never written down.
	//
	// It is a separate field rather than "zero means unknown" because the
	// two readings demand opposite reactions and a caller must be forced to
	// notice which one it has: "nothing here is old" and "I cannot tell you
	// whether anything here is old" are different claims, and collapsing
	// them into one number is how a metric starts lying in the reassuring
	// direction.
	AgeKnown bool
}

// Rebuild folds transitions into one Snapshot per entry, in first-seen
// order so the result is deterministic. A transition for an entry whose
// intent was never recorded is an error rather than a silently invented
// entry: it means the log is truncated in a way that would lose the effect.
func Rebuild(records []Record) ([]Snapshot, error) {
	index := map[string]int{}
	var out []Snapshot
	for _, rec := range records {
		pos, seen := index[rec.EntryID]
		if !seen {
			if rec.State != StateIntent {
				return nil, fmt.Errorf("outboxlog: entry %q has a %q transition with no recorded intent -- the log is truncated",
					rec.EntryID, rec.State)
			}
			if rec.Effect == nil {
				return nil, fmt.Errorf("outboxlog: entry %q intent carries no effect", rec.EntryID)
			}
			effect, err := DecodeEffect(*rec.Effect)
			if err != nil {
				return nil, fmt.Errorf("outboxlog: entry %q: %w", rec.EntryID, err)
			}
			out = append(out, Snapshot{
				EntryID:             rec.EntryID,
				State:               rec.State,
				IdempotencyKey:      rec.IdempotencyKey,
				Attempts:            rec.Attempts,
				Effect:              effect,
				JournaledAtUnixNano: rec.JournaledAtUnixNano,
				AgeKnown:            rec.JournaledAtUnixNano != 0,
			})
			index[rec.EntryID] = len(out) - 1
			continue
		}
		snap := &out[pos]
		snap.State = rec.State
		if rec.Attempts > snap.Attempts {
			snap.Attempts = rec.Attempts
		}
		if rec.IdempotencyKey != "" {
			snap.IdempotencyKey = rec.IdempotencyKey
		}
	}
	return out, nil
}
