package store

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/<OWNER>/<SERVICE>/internal/domain"
	"github.com/<OWNER>/<SERVICE>/internal/platform/outboxlog"
)

// downSink is a sink that can be switched between failing and working, so a
// test can drive an outage and then a recovery.
type downSink struct {
	mu        sync.Mutex
	down      bool
	delivered []string
}

func (s *downSink) Deliver(_ context.Context, key string, _ Entry) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.down {
		return errors.New("downSink: sink is down")
	}
	s.delivered = append(s.delivered, key)
	return nil
}

func (s *downSink) recover() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.down = false
}

func (s *downSink) deliveredCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.delivered)
}

func depositEffect(id string) domain.Effect {
	return domain.EffectDeposited{EventID: id, Amount: "1"}
}

// provenance: derived
// verifies: the pending bound HOLDS under a downed sink, what crossed it is
// dead-lettered rather than lost, and the still-pending entries drain once
// the sink returns.
//
// This is the whole point of the bound. Before it, a sink outage grew the
// outbox without limit -- in memory and in the durable log -- on a service
// that went on reporting itself healthy the entire time, because nothing
// about an unbounded queue is unhealthy until the process dies.
func TestOutbox_PendingBoundHoldsUnderAnOutageAndNothingIsLost(t *testing.T) {
	const bound = 5
	const journaled = 20

	sink := &downSink{down: true}
	dir := t.TempDir()
	path := filepath.Join(dir, "outbox.jsonl")

	clock := newStepClock(time.Unix(1_750_000_000, 0))
	ob, err := OpenDurable(path, sink, testIDs(), 1,
		WithLimits(Limits{MaxPending: bound}), WithClock(clock.now))
	if err != nil {
		t.Fatalf("OpenDurable: %v", err)
	}

	ids := make([]string, 0, journaled)
	for i := 0; i < journaled; i++ {
		id, err := ob.Journal(depositEffect("d"))
		if err != nil {
			t.Fatalf("Journal %d: %v", i, err)
		}
		ids = append(ids, id)
		// Publishing against a down sink is what a real fold does; it fails
		// and the entry stays pending.
		_ = ob.Publish(context.Background(), id)
	}

	// THE BOUND HOLDS.
	pending := ob.Pending()
	if len(pending) > bound {
		t.Fatalf("pending = %d after journaling %d against a down sink, want at most %d -- "+
			"the bound did not hold and the outbox is growing without limit", len(pending), journaled, bound)
	}

	// NOTHING IS LOST: every entry is either still pending or dead-lettered.
	dead := ob.DeadLettered()
	if len(pending)+len(dead) != journaled {
		t.Fatalf("pending %d + dead-lettered %d = %d, want %d -- %d effects vanished, which "+
			"is the one outcome the outbox pattern exists to prevent",
			len(pending), len(dead), len(pending)+len(dead), journaled, journaled-len(pending)-len(dead))
	}
	if ob.DeadLetterCount() != len(dead) {
		t.Errorf("DeadLetterCount = %d but DeadLettered lists %d", ob.DeadLetterCount(), len(dead))
	}
	if len(dead) == 0 {
		t.Fatal("nothing was dead-lettered, so this test never exercised the bound")
	}

	// AND IT SURVIVES A RESTART: the durable log, not memory, is the record.
	if err := ob.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	reopened, err := OpenDurable(path, sink, testIDs(), 1,
		WithLimits(Limits{MaxPending: bound}), WithClock(clock.now))
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer func() { _ = reopened.Close() }()
	if got := len(reopened.Pending()); got != len(pending) {
		t.Errorf("pending after restart = %d, want %d", got, len(pending))
	}
	if got := len(reopened.DeadLettered()); got != len(dead) {
		t.Errorf("dead-lettered after restart = %d, want %d -- an eviction that does not "+
			"survive a restart would resurrect work the bound retired", got, len(dead))
	}

	// THE SURVIVORS DRAIN once the sink comes back.
	sink.recover()
	result := reopened.Reconcile(context.Background())
	if result.StillDown != 0 {
		t.Errorf("Reconcile left %d entries undelivered against a healthy sink", result.StillDown)
	}
	if got := len(reopened.Pending()); got != 0 {
		t.Fatalf("%d entries still pending after the sink recovered", got)
	}
	if sink.deliveredCount() != len(pending) {
		t.Errorf("sink received %d, want the %d that were still pending", sink.deliveredCount(), len(pending))
	}
	// Dead-lettered entries are NOT resurrected automatically -- that would
	// defeat the bound that evicted them.
	if got := len(reopened.DeadLettered()); got != len(dead) {
		t.Errorf("dead-lettered = %d after Reconcile, want %d unchanged", got, len(dead))
	}
	_ = ids
}

// provenance: derived
// verifies: the AGE bound evicts a stale entry that the count bound would
// never notice.
//
// The two bounds are not redundant. One entry stuck for a week never fills a
// count bound, and when it is finally resurrected it lands outside any
// receiver's dedup window -- so it is stored twice, defeating the
// idempotency key.
func TestOutbox_AgeBoundEvictsAStaleEntryTheCountBoundWouldMiss(t *testing.T) {
	sink := &downSink{down: true}
	clock := newStepClock(time.Unix(1_750_000_000, 0))
	ob := NewOutbox(sink, testIDs(), 1,
		WithLimits(Limits{MaxPending: 1000, MaxPendingAge: time.Hour}), WithClock(clock.now))

	stale, err := ob.Journal(depositEffect("old"))
	if err != nil {
		t.Fatalf("Journal: %v", err)
	}
	_ = ob.Publish(context.Background(), stale)

	if got := len(ob.Pending()); got != 1 {
		t.Fatalf("precondition: pending = %d, want 1", got)
	}
	clock.advance(2 * time.Hour)

	// Any Journal enforces the bounds; this one is the trigger, not the
	// subject.
	if _, err := ob.Journal(depositEffect("new")); err != nil {
		t.Fatalf("Journal: %v", err)
	}

	for _, e := range ob.Pending() {
		if e.ID == stale {
			t.Fatalf("the 2-hour-old entry is still pending under a 1-hour age bound -- "+
				"nothing would ever evict it, and pending count (%d) is nowhere near its bound",
				len(ob.Pending()))
		}
	}
	dead := ob.DeadLettered()
	if len(dead) != 1 || dead[0].ID != stale {
		t.Fatalf("dead-lettered = %+v, want exactly the stale entry %q", dead, stale)
	}
}

// provenance: derived
// verifies: an entry replayed from schema 1 has no known age, is reported as
// such, and is NOT evicted by the age bound on a guess.
//
// Evicting it would make a version bump look like an outage; treating it as
// brand new would let it sit forever. Reporting the uncertainty separately is
// the only answer that is not a lie in one direction or the other.
func TestOutbox_UnknownAgeEntriesAreCountedSeparatelyAndNotEvictedOnAGuess(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "outbox.jsonl")

	// A schema-1 intent: no journaled_at_unix_nano.
	log, err := outboxlog.Open(path)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	legacy := outboxlog.Record{
		SchemaVersion: 1, EntryID: "legacy-1", State: outboxlog.StateIntent,
		IdempotencyKey: "k-legacy",
		Effect:         &outboxlog.EffectEnvelope{Kind: outboxlog.KindDeposited, EventID: "d1", Amount: "1"},
	}
	if err := log.Append(legacy); err != nil {
		t.Fatalf("append: %v", err)
	}
	_ = log.Close()
	// Append writes the CURRENT schema version, so rewrite the line as v1 to
	// get a genuine legacy record rather than a v2 one with a zero timestamp.
	if err := writeRawLine(path, `{"schema_version":1,"entry_id":"legacy-1","state":"intent","idempotency_key":"k-legacy","effect":{"kind":"deposited","event_id":"d1","amount":"1"}}`); err != nil {
		t.Fatalf("rewrite as v1: %v", err)
	}

	clock := newStepClock(time.Unix(1_750_000_000, 0))
	ob, err := OpenDurable(path, &downSink{down: true}, testIDs(), 1,
		WithLimits(Limits{MaxPending: 100, MaxPendingAge: time.Minute}), WithClock(clock.now))
	if err != nil {
		t.Fatalf("OpenDurable: %v", err)
	}
	defer func() { _ = ob.Close() }()

	count, oldest, unknown := ob.PendingStats()
	if count != 1 || unknown != 1 {
		t.Fatalf("PendingStats = (count %d, oldest %v, unknown %d), want 1 pending of unknown age",
			count, oldest, unknown)
	}
	if oldest != 0 {
		t.Errorf("oldestAge = %v, want 0 -- an unknown age must not be folded into the "+
			"known-age reading, or the number reassures about entries nobody measured", oldest)
	}

	clock.advance(time.Hour)
	if _, err := ob.Journal(depositEffect("trigger")); err != nil {
		t.Fatalf("Journal: %v", err)
	}
	for _, e := range ob.DeadLettered() {
		if e.ID == "legacy-1" {
			t.Fatal("the unknown-age entry was evicted by the age bound -- its age was never " +
				"recorded, so that eviction is a guess dressed as a measurement")
		}
	}
}

// provenance: derived
// verifies: Requeue is the way back from a dead-letter, keeping the SAME
// idempotency key -- which is what makes dead-lettering a pause rather than
// a deletion.
func TestOutbox_RequeueReturnsADeadLetteredEntryToPending(t *testing.T) {
	sink := &downSink{down: true}
	clock := newStepClock(time.Unix(1_750_000_000, 0))
	ob := NewOutbox(sink, testIDs(), 1, WithLimits(Limits{MaxPending: 1}), WithClock(clock.now))

	first, _ := ob.Journal(depositEffect("a"))
	_ = ob.Publish(context.Background(), first)
	if _, err := ob.Journal(depositEffect("b")); err != nil { // evicts `first`
		t.Fatalf("Journal: %v", err)
	}

	dead := ob.DeadLettered()
	if len(dead) != 1 || dead[0].ID != first {
		t.Fatalf("dead-lettered = %+v, want the first entry", dead)
	}
	keyBefore := dead[0].IdempotencyKey

	if err := ob.Requeue(first); err != nil {
		t.Fatalf("Requeue: %v", err)
	}
	entry, ok := ob.Entry(first)
	if !ok || entry.State != StateIntent {
		t.Fatalf("after Requeue, entry = %+v (ok=%v), want state intent", entry, ok)
	}
	if entry.IdempotencyKey != keyBefore {
		t.Errorf("Requeue changed the idempotency key %q -> %q -- a receiver would see the "+
			"requeued delivery as a different effect and store it twice",
			keyBefore, entry.IdempotencyKey)
	}
	if err := ob.Requeue(first); !errors.Is(err, ErrNotDeadLettered) {
		t.Errorf("Requeue of an already-pending entry: err = %v, want ErrNotDeadLettered", err)
	}
}

// writeRawLine replaces the file with exactly one raw line, so a test can
// produce a genuine schema-1 record that Append (which always stamps the
// current version) cannot write.
func writeRawLine(path, line string) error {
	return os.WriteFile(path, []byte(line+"\n"), 0o644)
}

// provenance: derived
// verifies: an entry's age is measured from when it was JOURNALED, not from
// when the process that inherited it started.
//
// This is the assertion whose absence let a mutation through: the bounds
// tests above reopen the log but never advance the clock across the restart,
// so they could not tell a restored timestamp from a fresh one. Without it,
// an entry stuck for a day comes back looking newly journaled, the age bound
// resets on every restart, and a crash-looping service never evicts anything
// -- the alert that fires on age would never fire for the effect that most
// needs it.
func TestOutbox_EntryAgeSurvivesARestart(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "outbox.jsonl")
	clock := newStepClock(time.Unix(1_750_000_000, 0))

	ob, err := OpenDurable(path, &downSink{down: true}, testIDs(), 1, WithClock(clock.now))
	if err != nil {
		t.Fatalf("OpenDurable: %v", err)
	}
	id, err := ob.Journal(depositEffect("d"))
	if err != nil {
		t.Fatalf("Journal: %v", err)
	}
	_ = ob.Publish(context.Background(), id)
	if err := ob.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	// Eight hours pass while the process is down.
	clock.advance(8 * time.Hour)

	reopened, err := OpenDurable(path, &downSink{down: true}, testIDs(), 1, WithClock(clock.now))
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer func() { _ = reopened.Close() }()

	count, oldest, unknown := reopened.PendingStats()
	if count != 1 {
		t.Fatalf("pending after restart = %d, want 1", count)
	}
	if unknown != 0 {
		t.Fatalf("the restored entry reports an UNKNOWN age, but it was journaled by this "+
			"very test under schema %d -- its timestamp should have survived", outboxlog.SchemaVersion)
	}
	if oldest != 8*time.Hour {
		t.Fatalf("age after the restart = %v, want 8h -- the entry came back looking freshly "+
			"journaled, so the age bound resets on every restart and a crash-looping service "+
			"would never evict anything", oldest)
	}
}

// stepClock is a manually advanced clock, so ages in these tests are exact
// rather than racing the wall clock.
type stepClock struct {
	mu sync.Mutex
	t  time.Time
}

func newStepClock(start time.Time) *stepClock { return &stepClock{t: start} }

func (c *stepClock) now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.t
}

func (c *stepClock) advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.t = c.t.Add(d)
}

// provenance: derived
// verifies: the retention bound forgets TERMINAL entries and never a
// pending one.
//
// Bounding only the pending set would have left two leaks: dead-lettered
// entries piling up as the very bound that evicted them filled memory, and
// -- predating any bound here -- every successfully DELIVERED entry retained
// for the life of the process, so a healthy high-throughput service grew
// without limit precisely because nothing was going wrong.
func TestOutbox_RetentionBoundForgetsTerminalEntriesButNeverPendingOnes(t *testing.T) {
	sink := &downSink{}
	clock := newStepClock(time.Unix(1_750_000_000, 0))
	ob := NewOutbox(sink, testIDs(), 1,
		WithLimits(Limits{MaxPending: 2, MaxRetained: 3}), WithClock(clock.now))
	ctx := context.Background()

	// Six delivered entries against a healthy sink: all terminal.
	var deliveredIDs []string
	for i := 0; i < 6; i++ {
		id, err := ob.Journal(depositEffect("d"))
		if err != nil {
			t.Fatalf("Journal %d: %v", i, err)
		}
		if err := ob.Publish(ctx, id); err != nil {
			t.Fatalf("Publish %d: %v", i, err)
		}
		deliveredIDs = append(deliveredIDs, id)
		clock.advance(time.Second)
	}

	if got := len(ob.entries); got > 3 {
		t.Fatalf("retained %d entries under a MaxRetained of 3 -- delivered entries are "+
			"accumulating for the life of the process", got)
	}
	// The OLDEST are the ones forgotten, and they are still in the durable
	// log; only the in-memory copy went.
	if _, ok := ob.Entry(deliveredIDs[0]); ok {
		t.Error("the oldest delivered entry is still retained; eviction picked the wrong end")
	}

}

// provenance: derived
// verifies: the retention bound never forgets an entry that is still
// PENDING, however much terminal churn is pushing against it.
//
// Retention evicts from memory, and a terminal entry can afford that because
// its transitions are already in the durable log and nothing is waiting on
// it. A pending entry cannot: forgetting it drops an effect that was never
// delivered, which is the one outcome no bound here may ever produce.
func TestOutbox_RetentionBoundNeverForgetsAPendingEntry(t *testing.T) {
	sink := &downSink{}
	clock := newStepClock(time.Unix(1_750_000_000, 0))
	// MaxPending high so the pending entry is never dead-lettered by the
	// COUNT bound -- this test is about retention, not eviction.
	ob := NewOutbox(sink, testIDs(), 1,
		WithLimits(Limits{MaxPending: 100, MaxRetained: 3}), WithClock(clock.now))
	ctx := context.Background()

	sink.mu.Lock()
	sink.down = true
	sink.mu.Unlock()
	stuck, err := ob.Journal(depositEffect("stuck"))
	if err != nil {
		t.Fatalf("Journal: %v", err)
	}
	_ = ob.Publish(ctx, stuck)

	// Now pile on terminal churn well past MaxRetained.
	sink.recover()
	for i := 0; i < 12; i++ {
		clock.advance(time.Second)
		id, err := ob.Journal(depositEffect("churn"))
		if err != nil {
			t.Fatalf("Journal %d: %v", i, err)
		}
		if err := ob.Publish(ctx, id); err != nil {
			t.Fatalf("Publish %d: %v", i, err)
		}
	}

	entry, ok := ob.Entry(stuck)
	if !ok {
		t.Fatal("the pending entry was forgotten by the retention bound -- an effect that " +
			"was never delivered is simply gone, which no bound here may ever do")
	}
	if entry.State != StateIntent && entry.State != StateFailed {
		t.Errorf("the pending entry is now %q, want it still pending", entry.State)
	}
}

// provenance: derived
// verifies: zero means "use the default", never "unbounded" -- and a
// retention bound below the pending bound is raised rather than allowed to
// evict entries still waiting to be delivered.
func TestLimits_DefaultsAndClamp(t *testing.T) {
	got := Limits{}.withDefaults()
	if got.MaxPending != DefaultMaxPending || got.MaxPendingAge != DefaultMaxPendingAge || got.MaxRetained != DefaultMaxRetained {
		t.Errorf("zero Limits = %+v, want the defaults -- an unfilled field must not mean "+
			"unbounded, which is the defect these bounds exist to remove", got)
	}
	clamped := Limits{MaxPending: 500, MaxRetained: 10}.withDefaults()
	if clamped.MaxRetained < clamped.MaxPending {
		t.Errorf("MaxRetained %d is below MaxPending %d -- retention would evict entries that "+
			"are still waiting to be delivered, the one thing neither bound may do",
			clamped.MaxRetained, clamped.MaxPending)
	}
}

// provenance: derived
// verifies: Requeue reports an unknown id rather than inventing an entry.
func TestOutbox_RequeueUnknownIDErrors(t *testing.T) {
	ob := NewOutbox(&downSink{}, testIDs(), 1)
	if err := ob.Requeue("no-such-entry"); err == nil {
		t.Fatal("Requeue of an unknown id returned nil")
	}
}

// provenance: derived
// verifies: PendingStats ignores terminal entries -- a delivered effect is
// not backlog, and counting it as such would make a healthy service look
// permanently behind.
func TestOutbox_PendingStatsIgnoresTerminalEntries(t *testing.T) {
	sink := &downSink{}
	clock := newStepClock(time.Unix(1_750_000_000, 0))
	ob := NewOutbox(sink, testIDs(), 1, WithClock(clock.now))
	ctx := context.Background()

	id, _ := ob.Journal(depositEffect("delivered"))
	if err := ob.Publish(ctx, id); err != nil {
		t.Fatalf("Publish: %v", err)
	}
	if count, _, _ := ob.PendingStats(); count != 0 {
		t.Fatalf("pending = %d with everything delivered, want 0", count)
	}

	sink.mu.Lock()
	sink.down = true
	sink.mu.Unlock()
	stuck, _ := ob.Journal(depositEffect("stuck"))
	_ = ob.Publish(ctx, stuck)
	clock.advance(90 * time.Second)

	count, oldest, unknown := ob.PendingStats()
	if count != 1 || unknown != 0 || oldest != 90*time.Second {
		t.Errorf("PendingStats = (%d, %v, %d), want (1, 90s, 0)", count, oldest, unknown)
	}
}

// provenance: derived
// verifies: JournalDerived is idempotent on IDENTITY, and the identity
// becomes the entry's idempotency key.
//
// Both halves are load-bearing for the boot-time reconstruction that closes
// the window between the state commit and the effect journal. If a repeated
// identity created a second entry, every restart would redeliver the whole
// deliverable history; if the identity were not the key, a resumed delivery
// would reach the sink as a brand-new effect and the deduplication that makes
// at-least-once tolerable would do nothing.
func TestOutbox_JournalDerivedIsIdempotentOnIdentity(t *testing.T) {
	ob := NewOutbox(&downSink{}, testIDs(), 3)

	first, err := ob.JournalDerived("ev1#0", domain.EffectDeposited{EventID: "ev1", Amount: "1"})
	if err != nil {
		t.Fatalf("first JournalDerived: %v", err)
	}
	second, err := ob.JournalDerived("ev1#0", domain.EffectDeposited{EventID: "ev1", Amount: "1"})
	if err != nil {
		t.Fatalf("second JournalDerived: %v", err)
	}

	if first != second {
		t.Fatalf("the same identity produced two entries (%s, %s) -- every restart "+
			"would re-journal the whole deliverable history", first, second)
	}
	if got := len(ob.Pending()); got != 1 {
		t.Fatalf("pending = %d, want 1", got)
	}
	if got := ob.Pending()[0].IdempotencyKey; got != "ev1#0" {
		t.Fatalf("idempotency key = %q, want the identity %q", got, "ev1#0")
	}
}

// provenance: derived
// verifies: JournalDerived refuses an empty identity rather than minting one.
// An entry with no identity cannot be recognised on the next boot, so it would
// be re-journaled forever.
func TestOutbox_JournalDerivedRefusesAnEmptyIdentity(t *testing.T) {
	ob := NewOutbox(&downSink{}, testIDs(), 3)
	if _, err := ob.JournalDerived("", domain.EffectDeposited{EventID: "e", Amount: "1"}); err == nil {
		t.Fatal("JournalDerived accepted an empty identity")
	}
}

// provenance: derived
// verifies: KnowsIdentity recognises an entry in ANY state, including
// delivered. Recognising only PENDING entries would make the boot-time
// reconstruction re-journal everything the sink had already received --
// trading a rare lost effect for a guaranteed redelivery storm on every
// restart.
func TestOutbox_KnowsIdentityRecognisesDeliveredEntriesToo(t *testing.T) {
	ob := NewOutbox(&downSink{}, testIDs(), 3)

	id, err := ob.JournalDerived("ev9#0", domain.EffectDeposited{EventID: "ev9", Amount: "1"})
	if err != nil {
		t.Fatalf("JournalDerived: %v", err)
	}
	if !ob.KnowsIdentity("ev9#0") {
		t.Fatal("KnowsIdentity = false for an entry it just journaled")
	}
	if err := ob.Publish(context.Background(), id); err != nil {
		t.Fatalf("Publish: %v", err)
	}
	if !ob.KnowsIdentity("ev9#0") {
		t.Fatal("KnowsIdentity = false once the entry was DELIVERED -- the rebuild " +
			"would re-journal effects the sink already has")
	}
	if ob.KnowsIdentity("never-journaled#0") {
		t.Fatal("KnowsIdentity = true for an identity nobody journaled")
	}
}
