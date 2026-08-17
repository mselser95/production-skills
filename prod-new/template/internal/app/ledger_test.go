package app

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/<OWNER>/<SERVICE>/internal/domain"
)

// fakeJournal is an in-memory EventJournal test double.
type fakeJournal struct {
	mu       sync.Mutex
	events   []domain.Event
	failNext bool
}

func (f *fakeJournal) Append(e domain.Event) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.failNext {
		f.failNext = false
		return errors.New("journal: simulated append failure")
	}
	f.events = append(f.events, e)
	return nil
}

// fakePublisher is an in-memory EffectPublisher test double, capturing every
// Journal/Publish call so tests can assert the outbox handoff happened.
type fakePublisher struct {
	mu          sync.Mutex
	journaled   []domain.Effect
	published   []string
	failPublish bool
	failJournal bool
	nextID      int
}

func (f *fakePublisher) Journal(effect domain.Effect) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.failJournal {
		return "", errors.New("outbox: simulated journal failure")
	}
	f.nextID++
	id := "entry-" + string(rune('0'+f.nextID))
	f.journaled = append(f.journaled, effect)
	return id, nil
}

func (f *fakePublisher) Publish(ctx context.Context, entryID string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.failPublish {
		return errors.New("outbox: simulated publish failure")
	}
	f.published = append(f.published, entryID)
	return nil
}

func newTestLedger() (*Ledger, *fakeJournal, *fakePublisher) {
	j := &fakeJournal{}
	p := &fakePublisher{}
	clk := func() time.Time { return time.Unix(1_700_000_000, 0) }
	n := 0
	ids := func() string { n++; return "gen-" + string(rune('0'+n)) }
	return NewLedger(domain.NewState(), j, p, clk, ids), j, p
}

// provenance: derived
// verifies: CommandOutcome.Stage names every commandState value, including
// the default/unknown case
func TestCommandState_StringNamesEveryValue(t *testing.T) {
	cases := map[commandState]string{
		csReceived:         "received",
		csLogged:           "logged",
		csApplied:          "applied",
		csEffectsJournaled: "effects_journaled",
		csCommitted:        "committed",
		commandState(999):  "unknown",
	}
	for state, want := range cases {
		if got := state.String(); got != want {
			t.Errorf("commandState(%d).String() = %q, want %q", state, got, want)
		}
	}
}

// provenance: derived
// verifies: app.Ledger orchestration -- a deposit is journaled, applied,
// and its effect is journaled+published through the outbox (commandState:
// csReceived -> csLogged -> csApplied -> csEffectsJournaled -> csCommitted)
func TestLedger_Deposit_FullPipelineCommits(t *testing.T) {
	l, j, p := newTestLedger()
	outcome, err := l.Deposit(context.Background(), "e1", "10")
	if err != nil {
		t.Fatalf("Deposit: %v", err)
	}
	if outcome.State.Balance != "10.00000000" {
		t.Fatalf("balance = %q, want 10.00000000", outcome.State.Balance)
	}
	if !outcome.EffectsCommitted {
		t.Fatal("EffectsCommitted = false, want true")
	}
	if len(j.events) != 1 || j.events[0].ID != "e1" {
		t.Fatalf("journal = %+v, want one event e1", j.events)
	}
	if len(p.journaled) != 1 || len(p.published) != 1 {
		t.Fatalf("outbox journaled=%d published=%d, want 1 and 1", len(p.journaled), len(p.published))
	}
}

// provenance: derived
// verifies: app.Ledger orchestration (withdraw insufficient balance never
// reaches the outbox -- domain.Apply's own rejection is respected up the
// stack)
func TestLedger_Withdraw_InsufficientBalanceNeverJournalsAnOutboxEntry(t *testing.T) {
	l, _, p := newTestLedger()
	outcome, err := l.Withdraw(context.Background(), "e1", "5")
	if err != nil {
		t.Fatalf("Withdraw: %v", err)
	}
	if outcome.State.Balance != domain.ZeroAmount {
		t.Fatalf("balance = %q, want unchanged zero", outcome.State.Balance)
	}
	if len(p.journaled) != 0 {
		t.Fatalf("outbox journaled=%d, want 0 (nothing to notify for a rejected withdrawal)", len(p.journaled))
	}
	if _, ok := outcome.Effects[0].(domain.EffectWithdrawalRejected); !ok {
		t.Fatalf("effects[0] = %#v, want EffectWithdrawalRejected", outcome.Effects[0])
	}
}

// provenance: derived
// verifies: recovery semantics (csLogged: a journal append failure aborts
// the command BEFORE domain.Apply ever runs, so state is never mutated on
// a durability failure)
func TestLedger_JournalAppendFailure_NeverMutatesState(t *testing.T) {
	l, j, _ := newTestLedger()
	j.failNext = true
	before := l.State()
	_, err := l.Deposit(context.Background(), "e1", "10")
	if err == nil {
		t.Fatal("Deposit did not return an error on a journal append failure")
	}
	if after := l.State(); after.Balance != before.Balance || after.Version != before.Version {
		t.Fatalf("state changed despite a journal append failure: %+v -> %+v", before, after)
	}
}

// provenance: derived
// verifies: recovery semantics (csEffectsJournaled: an outbox Journal/
// Publish failure does NOT roll back the already-committed ledger state --
// the domain-level admission is durable and final the moment Apply ran; only
// the side notification is pending, EffectsCommitted=false says so)
func TestLedger_OutboxFailure_StateStillCommitsEffectsCommittedFalse(t *testing.T) {
	l, _, p := newTestLedger()
	p.failPublish = true
	outcome, err := l.Deposit(context.Background(), "e1", "10")
	if err != nil {
		t.Fatalf("Deposit: %v", err)
	}
	if outcome.State.Balance != "10.00000000" {
		t.Fatalf("balance = %q, want 10.00000000 even though the outbox publish failed", outcome.State.Balance)
	}
	if outcome.EffectsCommitted {
		t.Fatal("EffectsCommitted = true despite a publish failure")
	}
}

// provenance: derived
// verifies: idempotency at the orchestration layer -- Deposit called twice
// with the SAME eventID has the ledger's economic effect once (domain.Apply's
// own guarantee, exercised through the full app pipeline including the
// outbox, not just the pure core)
func TestLedger_Deposit_SameEventIDTwiceHasEffectOnce(t *testing.T) {
	l, _, p := newTestLedger()
	if _, err := l.Deposit(context.Background(), "e1", "10"); err != nil {
		t.Fatalf("first Deposit: %v", err)
	}
	outcome, err := l.Deposit(context.Background(), "e1", "10")
	if err != nil {
		t.Fatalf("second Deposit: %v", err)
	}
	if outcome.State.Balance != "10.00000000" {
		t.Fatalf("balance = %q after a duplicate deposit, want unchanged 10.00000000", outcome.State.Balance)
	}
	if len(p.journaled) != 1 {
		t.Fatalf("outbox journaled=%d entries, want 1 (the duplicate must not re-notify)", len(p.journaled))
	}
	if l.ConservationViolations() != 0 || l.DuplicateEffectViolations() != 0 {
		t.Fatalf("invariant counters = conservation:%d duplicate:%d, want 0,0", l.ConservationViolations(), l.DuplicateEffectViolations())
	}
}

// provenance: derived
// verifies: injected id/random port -- an empty eventID is minted via the
// injected IDGenerator, never left blank and never derived from the clock.
func TestLedger_Deposit_EmptyEventIDIsMintedByTheInjectedGenerator(t *testing.T) {
	l, j, _ := newTestLedger()
	if _, err := l.Deposit(context.Background(), "", "1"); err != nil {
		t.Fatalf("Deposit: %v", err)
	}
	if len(j.events) != 1 || j.events[0].ID == "" {
		t.Fatalf("journal = %+v, want one event with a non-empty minted ID", j.events)
	}
}
