package store

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"

	"github.com/<OWNER>/<SERVICE>/internal/domain"
)

func testIDs() IDGenerator {
	var n atomic.Uint64
	return func() string {
		v := n.Add(1)
		return fmt.Sprintf("id-%d", v)
	}
}

// provenance: derived
// verifies: outbox pattern (journal intent -> deliver -> mark done)
func TestOutbox_JournalThenPublish_MarksDelivered(t *testing.T) {
	sink := NewLogSink(nil)
	ob := NewOutbox(sink, testIDs(), 3)

	entryID, err := ob.Journal(domain.EffectDeposited{EventID: "e1", Amount: "10"})
	if err != nil {
		t.Fatalf("Journal: %v", err)
	}
	entry, ok := ob.Entry(entryID)
	if !ok || entry.State != StateIntent {
		t.Fatalf("entry after Journal = %+v (ok=%v), want StateIntent", entry, ok)
	}

	if err := ob.Publish(context.Background(), entryID); err != nil {
		t.Fatalf("Publish: %v", err)
	}
	entry, _ = ob.Entry(entryID)
	if entry.State != StateDelivered {
		t.Fatalf("entry.State = %q after successful Publish, want %q", entry.State, StateDelivered)
	}
	if entry.IdempotencyKey == "" {
		t.Fatal("entry.IdempotencyKey is empty after a successful Publish")
	}
}

// provenance: derived
// verifies: outbox pattern (idempotency key generated INSIDE the retry
// closure -- the SAME key must be presented to Sink.Deliver across every
// physical retry attempt within one logical Publish call)
func TestOutbox_Publish_ReusesTheSameIdempotencyKeyAcrossRetries(t *testing.T) {
	sink := NewLogSink(nil)
	sink.FailUntilAttempt = 3 // fail twice, succeed on the 3rd attempt for that key
	ob := NewOutbox(sink, testIDs(), 5)

	entryID, err := ob.Journal(domain.EffectWithdrawn{EventID: "e1", Amount: "4"})
	if err != nil {
		t.Fatalf("Journal: %v", err)
	}
	if err := ob.Publish(context.Background(), entryID); err != nil {
		t.Fatalf("Publish: %v", err)
	}
	entry, _ := ob.Entry(entryID)
	if got := sink.AttemptsFor(entry.IdempotencyKey); got != 3 {
		t.Fatalf("sink saw %d attempts under the final idempotency key, want 3 (all retries shared one key)", got)
	}
	if entry.Attempts != 3 {
		t.Fatalf("entry.Attempts = %d, want 3", entry.Attempts)
	}
}

// provenance: derived
// verifies: outbox pattern (a SEPARATE logical Publish call for a
// DIFFERENT entry gets its OWN idempotency key -- keys are not globally
// reused, only reused WITHIN one entry's retry loop)
func TestOutbox_Publish_DifferentEntriesGetDifferentIdempotencyKeys(t *testing.T) {
	sink := NewLogSink(nil)
	ob := NewOutbox(sink, testIDs(), 3)

	id1, _ := ob.Journal(domain.EffectDeposited{EventID: "e1", Amount: "1"})
	id2, _ := ob.Journal(domain.EffectDeposited{EventID: "e2", Amount: "2"})
	if err := ob.Publish(context.Background(), id1); err != nil {
		t.Fatalf("Publish id1: %v", err)
	}
	if err := ob.Publish(context.Background(), id2); err != nil {
		t.Fatalf("Publish id2: %v", err)
	}
	e1, _ := ob.Entry(id1)
	e2, _ := ob.Entry(id2)
	if e1.IdempotencyKey == e2.IdempotencyKey {
		t.Fatalf("two different entries got the same idempotency key: %q", e1.IdempotencyKey)
	}
}

// provenance: derived
// verifies: outbox pattern (max attempts exhausted -> StateFailed, a
// Reconcile candidate -- never retried forever)
func TestOutbox_Publish_ExhaustsMaxAttemptsAndMarksFailed(t *testing.T) {
	sink := NewLogSink(nil)
	sink.FailUntilAttempt = 100 // never succeeds within maxAttempts
	ob := NewOutbox(sink, testIDs(), 3)

	entryID, _ := ob.Journal(domain.EffectDeposited{EventID: "e1", Amount: "1"})
	if err := ob.Publish(context.Background(), entryID); err == nil {
		t.Fatal("Publish did not return an error after exhausting max attempts")
	}
	entry, _ := ob.Entry(entryID)
	if entry.State != StateFailed {
		t.Fatalf("entry.State = %q, want %q", entry.State, StateFailed)
	}
	if entry.Attempts != 3 {
		t.Fatalf("entry.Attempts = %d, want exactly maxAttempts=3 (never retried forever)", entry.Attempts)
	}
}

// provenance: derived
// verifies: recovery ("journal says X, world says Y" table-driven recovery
// -- tier-policy: recovery.tabular_recovery_tests required) -- Reconcile
// resumes every StateIntent/StateFailed entry and, once the sink recovers,
// delivers them.
func TestOutbox_Reconcile_ResumesPendingEntries(t *testing.T) {
	sink := NewLogSink(nil)
	sink.FailUntilAttempt = 100
	ob := NewOutbox(sink, testIDs(), 2)

	id1, _ := ob.Journal(domain.EffectDeposited{EventID: "e1", Amount: "1"})
	id2, _ := ob.Journal(domain.EffectDeposited{EventID: "e2", Amount: "2"})
	_ = ob.Publish(context.Background(), id1) // exhausts attempts -> StateFailed
	// id2 is left in StateIntent (Publish never called): both are "pending".

	if got := ob.Pending(); len(got) != 2 {
		t.Fatalf("Pending() = %d entries, want 2 (id1 failed, id2 still-intent)", len(got))
	}

	sink.FailUntilAttempt = 0 // the world recovers
	result := ob.Reconcile(context.Background())
	if result.Resumed != 2 || result.Delivered != 2 || result.StillDown != 0 {
		t.Fatalf("Reconcile() = %+v, want Resumed=2 Delivered=2 StillDown=0", result)
	}
	for _, id := range []string{id1, id2} {
		e, _ := ob.Entry(id)
		if e.State != StateDelivered {
			t.Fatalf("entry %s state = %q after Reconcile, want %q", id, e.State, StateDelivered)
		}
	}
	if got := ob.Pending(); len(got) != 0 {
		t.Fatalf("Pending() after a fully successful Reconcile = %d, want 0", len(got))
	}
}

// provenance: derived
// verifies: outbox pattern (Publish against an unknown entry id fails
// loudly rather than silently doing nothing)
func TestOutbox_Publish_UnknownEntryIDErrors(t *testing.T) {
	ob := NewOutbox(NewLogSink(nil), testIDs(), 3)
	if err := ob.Publish(context.Background(), "does-not-exist"); err == nil {
		t.Fatal("Publish(unknown entry id) did not error")
	}
}

// provenance: derived
// verifies: outbox pattern (Entry lookup on an unknown id reports ok=false
// rather than a zero-value Entry that looks like a real one)
func TestOutbox_Entry_UnknownIDReportsNotOK(t *testing.T) {
	ob := NewOutbox(NewLogSink(nil), testIDs(), 3)
	if _, ok := ob.Entry("does-not-exist"); ok {
		t.Fatal("Entry(unknown id) reported ok=true")
	}
}

// provenance: derived
// verifies: outbox pattern (NewOutbox defaults a non-positive maxAttempts
// to a sane floor rather than never retrying at all)
func TestNewOutbox_DefaultsNonPositiveMaxAttempts(t *testing.T) {
	sink := NewLogSink(nil)
	sink.FailUntilAttempt = 4
	ob := NewOutbox(sink, testIDs(), 0) // 0 -> defaults to 5
	id, err := ob.Journal(domain.EffectDeposited{EventID: "e1", Amount: "1"})
	if err != nil {
		t.Fatalf("Journal: %v", err)
	}
	if err := ob.Publish(context.Background(), id); err != nil {
		t.Fatalf("Publish: %v (want the default attempt budget to cover 4 attempts)", err)
	}
}

// keyRecordingSink records every idempotency key it is handed, so a test can
// assert on the sequence across MULTIPLE Publish invocations rather than only
// within one.
type keyRecordingSink struct {
	keys []string
	fail bool
}

func (s *keyRecordingSink) Deliver(_ context.Context, key string, _ Entry) error {
	s.keys = append(s.keys, key)
	if s.fail {
		return errors.New("sink down")
	}
	return nil
}

// provenance: derived
// verifies: idempotency_strategy (capability class external_effect) --
// the key identifies the ENTRY, so every delivery of one logical effect
// carries the same key even ACROSS separate Publish invocations.
//
// TestOutbox_Publish_ReusesTheSameIdempotencyKeyAcrossRetries covers retries
// WITHIN one Publish call. This one covers the case that actually broke: a
// Publish that exhausts its attempts against a down sink, then a Reconcile
// pass once the sink is back. Reconcile calls Publish afresh, so an
// implementation that mints the key per-invocation re-keys here and the
// receiver sees two unrelated effects instead of one repeated.
//
// Measured against the pre-fix implementation, which minted inside Publish's
// retry loop: the sink saw [id-2 id-2 id-3] for a single effect. No crash was
// required -- an ordinary recovery pass was enough.
func TestOutbox_IdempotencyKeyIsStableAcrossPublishInvocations(t *testing.T) {
	sink := &keyRecordingSink{fail: true}
	ob := NewOutbox(sink, testIDs(), 2)

	id, err := ob.Journal(domain.EffectDeposited{EventID: "e1", Amount: "10"})
	if err != nil {
		t.Fatalf("Journal: %v", err)
	}
	// First delivery: the sink is down, so this exhausts maxAttempts and
	// marks the entry failed -- a Reconcile candidate.
	if err := ob.Publish(context.Background(), id); err == nil {
		t.Fatal("Publish against a down sink returned nil")
	}

	sink.fail = false
	if got := ob.Reconcile(context.Background()); got.Delivered != 1 {
		t.Fatalf("Reconcile delivered %d, want 1", got.Delivered)
	}

	if len(sink.keys) < 2 {
		t.Fatalf("sink saw %d deliveries, want at least 2 (the scenario did not set up)", len(sink.keys))
	}
	for i, k := range sink.keys {
		if k != sink.keys[0] {
			t.Fatalf("delivery %d used key %q but delivery 0 used %q -- one logical effect "+
				"was delivered under two keys, so the receiver cannot collapse them and a "+
				"recovery pass double-delivers (keys: %v)", i, k, sink.keys[0], sink.keys)
		}
	}

	// And the key the entry reports must be that same one, so an operator
	// reading the outbox can correlate it with what the receiver saw.
	entry, ok := ob.Entry(id)
	if !ok || entry.IdempotencyKey != sink.keys[0] {
		t.Fatalf("entry.IdempotencyKey = %q, want the delivered key %q", entry.IdempotencyKey, sink.keys[0])
	}
}

// provenance: derived
// verifies: recovery (tier-policy: recovery.effect_journal =
// required_if_durable_effects) -- an intent journaled but NOT delivered
// survives a process restart and is resumed by Reconcile under the SAME
// idempotency key.
//
// This is the whole reason the outbox pattern exists. A first "process"
// journals an intent against a down sink; that process goes away entirely
// (its Outbox is closed and dropped); a second process opens the SAME path
// and must find the pending intent waiting.
func TestOutbox_DurableIntentSurvivesARestartAndResumesUnderTheSameKey(t *testing.T) {
	path := filepath.Join(t.TempDir(), "outbox.jsonl")

	// --- process 1: journal against a down sink, then die ---------------
	down := &keyRecordingSink{fail: true}
	first, err := OpenDurable(path, down, testIDs(), 2)
	if err != nil {
		t.Fatalf("OpenDurable: %v", err)
	}
	id, err := first.Journal(domain.EffectDeposited{EventID: "d1", Amount: "10"})
	if err != nil {
		t.Fatalf("Journal: %v", err)
	}
	if err := first.Publish(context.Background(), id); err == nil {
		t.Fatal("Publish against a down sink returned nil")
	}
	keyBefore, _ := first.Entry(id)
	if err := first.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	first = nil // the process is gone; nothing in memory survives

	// --- process 2: open the same path, find the intent ------------------
	up := &keyRecordingSink{}
	second, err := OpenDurable(path, up, testIDs(), 2)
	if err != nil {
		t.Fatalf("OpenDurable (restart): %v", err)
	}
	defer func() { _ = second.Close() }()

	recovered, ok := second.Entry(id)
	if !ok {
		t.Fatalf("entry %q did not survive the restart -- the outbox is not durable", id)
	}
	if recovered.State != StateFailed {
		t.Errorf("recovered state = %q, want %q", recovered.State, StateFailed)
	}
	if recovered.Effect != (domain.EffectDeposited{EventID: "d1", Amount: "10"}) {
		t.Errorf("recovered effect = %#v, want the journaled deposit", recovered.Effect)
	}
	if recovered.IdempotencyKey != keyBefore.IdempotencyKey {
		t.Fatalf("recovered key %q != pre-restart key %q -- a restart that re-keys "+
			"double-delivers exactly when it cannot know whether the sink already had it",
			recovered.IdempotencyKey, keyBefore.IdempotencyKey)
	}

	// --- and the recovery pass actually delivers it ----------------------
	if got := second.Reconcile(context.Background()); got.Delivered != 1 {
		t.Fatalf("Reconcile after restart delivered %d, want 1", got.Delivered)
	}
	if len(up.keys) == 0 {
		t.Fatal("the sink saw no delivery after the restart")
	}
	if up.keys[0] != keyBefore.IdempotencyKey {
		t.Errorf("post-restart delivery used key %q, want the original %q",
			up.keys[0], keyBefore.IdempotencyKey)
	}
}

// provenance: derived
// verifies: Journal REFUSES an effect the durable format cannot encode,
// rather than returning an id for an intent a restart would silently lose.
func TestOutbox_JournalRefusesAnUnencodableEffect(t *testing.T) {
	ob := NewOutbox(NewLogSink(nil), testIDs(), 3)
	id, err := ob.Journal(domain.EffectWithdrawalRejected{EventID: "x"})
	if err == nil {
		t.Fatal("Journal accepted an effect the durable format cannot represent")
	}
	if id != "" {
		t.Errorf("Journal returned id %q alongside an error -- the caller will think it was accepted", id)
	}
	if len(ob.Pending()) != 0 {
		t.Errorf("a refused effect left %d pending entries", len(ob.Pending()))
	}
}

// provenance: derived
// verifies: the NON-durable constructor is still fully functional -- the
// durability work must not have made the in-memory form a second-class path,
// since it is what every test in this package uses.
func TestOutbox_NonDurableFormStillWorks(t *testing.T) {
	ob := NewOutbox(NewLogSink(nil), testIDs(), 3)
	id, err := ob.Journal(domain.EffectDeposited{EventID: "d1", Amount: "1"})
	if err != nil {
		t.Fatalf("Journal: %v", err)
	}
	if err := ob.Publish(context.Background(), id); err != nil {
		t.Fatalf("Publish: %v", err)
	}
	if entry, _ := ob.Entry(id); entry.State != StateDelivered {
		t.Errorf("state = %q, want delivered", entry.State)
	}
	if err := ob.Close(); err != nil {
		t.Errorf("Close on a non-durable outbox: %v", err)
	}
}

// provenance: derived
// verifies: OpenDurable surfaces a corrupt or unreadable journal as an ERROR
// at boot rather than starting with a silently-empty outbox. A process that
// comes up "clean" because it could not read its own intents has lost them
// without saying so.
func TestOpenDurable_RefusesToStartOnAnUnreadableJournal(t *testing.T) {
	t.Run("corrupt line", func(t *testing.T) {
		path := filepath.Join(t.TempDir(), "outbox.jsonl")
		if err := os.WriteFile(path, []byte("{not json at all}\n"), 0o644); err != nil {
			t.Fatalf("seed: %v", err)
		}
		if _, err := OpenDurable(path, NewLogSink(nil), testIDs(), 3); err == nil {
			t.Fatal("OpenDurable started on a corrupt journal")
		}
	})

	t.Run("transition with no intent", func(t *testing.T) {
		path := filepath.Join(t.TempDir(), "outbox.jsonl")
		line := `{"schema_version":1,"entry_id":"e-1","state":"delivered"}` + "\n"
		if err := os.WriteFile(path, []byte(line), 0o644); err != nil {
			t.Fatalf("seed: %v", err)
		}
		if _, err := OpenDurable(path, NewLogSink(nil), testIDs(), 3); err == nil {
			t.Fatal("OpenDurable started on a truncated journal")
		}
	})

	t.Run("path is a directory", func(t *testing.T) {
		dir := t.TempDir()
		if _, err := OpenDurable(dir, NewLogSink(nil), testIDs(), 3); err == nil {
			t.Fatal("OpenDurable accepted a directory as its journal path")
		}
	})
}

// provenance: derived
// verifies: an empty/absent journal is a legitimate cold start, not an error
// -- the very first boot of a service must not fail on a file it has not
// written yet.
func TestOpenDurable_ColdStartOnAnAbsentJournal(t *testing.T) {
	path := filepath.Join(t.TempDir(), "does-not-exist-yet.jsonl")
	ob, err := OpenDurable(path, NewLogSink(nil), testIDs(), 3)
	if err != nil {
		t.Fatalf("OpenDurable on a fresh path: %v", err)
	}
	defer func() { _ = ob.Close() }()
	if len(ob.Pending()) != 0 {
		t.Errorf("cold start found %d pending entries", len(ob.Pending()))
	}
	if _, err := ob.Journal(domain.EffectDeposited{EventID: "d1", Amount: "1"}); err != nil {
		t.Fatalf("Journal after cold start: %v", err)
	}
}

// provenance: derived
// verifies: Reconcile reports entries it could NOT deliver rather than
// counting them as resumed-and-done -- the StillDown branch.
func TestOutbox_Reconcile_ReportsEntriesItCouldNotDeliver(t *testing.T) {
	sink := &keyRecordingSink{fail: true}
	ob := NewOutbox(sink, testIDs(), 1)
	if _, err := ob.Journal(domain.EffectDeposited{EventID: "d1", Amount: "1"}); err != nil {
		t.Fatalf("Journal: %v", err)
	}
	got := ob.Reconcile(context.Background())
	if got.Resumed != 1 {
		t.Errorf("Resumed = %d, want 1", got.Resumed)
	}
	if got.StillDown != 1 {
		t.Errorf("StillDown = %d, want 1 -- a still-failing entry was counted as delivered", got.StillDown)
	}
	if got.Delivered != 0 {
		t.Errorf("Delivered = %d, want 0", got.Delivered)
	}
}
