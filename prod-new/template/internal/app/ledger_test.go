package app

import (
	"context"
	"errors"
	"fmt"
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
	entered  chan struct{}
	release  chan struct{}
}

// gate, when non-nil, blocks the FIRST Append until released, with the
// calling goroutine parked inside Append. It exists to make the
// decide/journal/commit critical section OBSERVABLE: whether a second
// command can make progress while the first is parked in Append is exactly
// the question of whether the lock is held across it.
func (f *fakeJournal) arm() (entered <-chan struct{}, release func()) {
	e, r := make(chan struct{}), make(chan struct{})
	f.mu.Lock()
	f.entered, f.release = e, r
	f.mu.Unlock()
	return e, func() { close(r) }
}

func (f *fakeJournal) count() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.events)
}

func (f *fakeJournal) Append(_ context.Context, e domain.Event) error {
	f.mu.Lock()
	gateEntered, gateRelease := f.entered, f.release
	f.entered, f.release = nil, nil
	f.mu.Unlock()
	if gateEntered != nil {
		close(gateEntered)
		<-gateRelease
	}

	f.mu.Lock()
	defer f.mu.Unlock()
	if f.failNext {
		f.failNext = false
		return errors.New("journal: simulated append failure")
	}
	f.events = append(f.events, e)
	return nil
}

// fakeNotifier counts relay nudges and records how many events were already
// durable at the moment of each one, so a test can assert the nudge happens
// AFTER the append rather than merely that it happened.
type fakeNotifier struct {
	mu             sync.Mutex
	calls          int
	durableAtNudge []int
	journal        *fakeJournal
}

func (f *fakeNotifier) notify() {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls++
	f.durableAtNudge = append(f.durableAtNudge, f.journal.count())
}

func (f *fakeNotifier) Calls() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.calls
}

func newTestLedger() (*Ledger, *fakeJournal, *fakeNotifier) {
	j := &fakeJournal{}
	n := &fakeNotifier{journal: j}
	clk := func() time.Time { return time.Unix(1_700_000_000, 0) }
	i := 0
	ids := func() string { i++; return "gen-" + string(rune('0'+i)) }
	return NewLedger(domain.NewState(), j, n.notify, clk, ids), j, n
}

// provenance: derived
// verifies: CommandOutcome.Stage names every commandState value, including
// the default/unknown case
func TestCommandState_StringNamesEveryValue(t *testing.T) {
	cases := map[commandState]string{
		csReceived:        "received",
		csApplied:         "applied",
		csLogged:          "logged",
		csCommitted:       "committed",
		commandState(999): "unknown",
	}
	for state, want := range cases {
		if got := state.String(); got != want {
			t.Errorf("commandState(%d).String() = %q, want %q", state, got, want)
		}
	}
}

// provenance: derived
// verifies: app.Ledger orchestration -- an admitted deposit is applied,
// journaled and nudged (commandState: csReceived -> csApplied -> csLogged
// -> csCommitted), and the nudge lands only AFTER the event is durable
func TestLedger_Deposit_FullPipelineCommits(t *testing.T) {
	l, j, n := newTestLedger()
	outcome, err := l.Deposit(context.Background(), "e1", "10")
	if err != nil {
		t.Fatalf("Deposit: %v", err)
	}
	if outcome.State.Balance != "10.00000000" {
		t.Fatalf("balance = %q, want 10.00000000", outcome.State.Balance)
	}
	if outcome.Stage != csCommitted.String() {
		t.Fatalf("stage = %q, want %q", outcome.Stage, csCommitted)
	}
	if len(j.events) != 1 || j.events[0].ID != "e1" {
		t.Fatalf("journal = %+v, want one event e1", j.events)
	}
	if n.Calls() != 1 {
		t.Fatalf("relay nudges = %d, want 1", n.Calls())
	}
	// The nudge must observe the event already in the log. Nudging first
	// would send the relay to read a log that does not yet contain the
	// event; it would find nothing, and delivery would then wait out the
	// full idle interval instead of being immediate.
	if got := n.durableAtNudge; len(got) != 1 || got[0] != 1 {
		t.Fatalf("durable events at nudge = %v, want [1] (nudge after the append)", got)
	}
}

// provenance: derived
// verifies: app.Ledger orchestration -- a withdrawal the domain REJECTS is
// never appended to the event log and never nudges the relay, so the log
// keeps its contract ("everything in here happened") and the relay's mapper
// never has to re-decide admission
func TestLedger_Withdraw_InsufficientBalanceIsNeverJournaled(t *testing.T) {
	l, j, n := newTestLedger()
	outcome, err := l.Withdraw(context.Background(), "e1", "5")
	if err != nil {
		t.Fatalf("Withdraw: %v", err)
	}
	if outcome.State.Balance != domain.ZeroAmount {
		t.Fatalf("balance = %q, want unchanged zero", outcome.State.Balance)
	}
	if len(j.events) != 0 {
		t.Fatalf("journal = %+v, want empty (a rejected withdrawal is not a fact)", j.events)
	}
	if n.Calls() != 0 {
		t.Fatalf("relay nudges = %d, want 0 for a rejected command", n.Calls())
	}
	if _, ok := outcome.Effects[0].(domain.EffectWithdrawalRejected); !ok {
		t.Fatalf("effects[0] = %#v, want EffectWithdrawalRejected", outcome.Effects[0])
	}
}

// provenance: derived
// verifies: recovery semantics (csApplied -> csLogged: the decision is made
// in memory FIRST, and a journal append failure discards it, so committed
// state never runs ahead of the durable log)
func TestLedger_JournalAppendFailure_NeverMutatesStateAndNeverNudges(t *testing.T) {
	l, j, n := newTestLedger()
	j.failNext = true
	before := l.State()
	outcome, err := l.Deposit(context.Background(), "e1", "10")
	if err == nil {
		t.Fatal("Deposit did not return an error on a journal append failure")
	}
	if after := l.State(); after.Balance != before.Balance || after.Version != before.Version {
		t.Fatalf("state changed despite a journal append failure: %+v -> %+v", before, after)
	}
	if outcome.Stage != csApplied.String() {
		t.Fatalf("stage = %q, want %q (decided, never made durable)", outcome.Stage, csApplied)
	}
	// A nudge here would send the relay to look for an event that does not
	// exist; harmless once, but it is also the honest signal that this layer
	// knows nothing was written.
	if n.Calls() != 0 {
		t.Fatalf("relay nudges = %d, want 0 when the append failed", n.Calls())
	}
}

// provenance: derived
// verifies: decide/journal/commit is ONE critical section -- no second
// command can decide while the first is between domain.Apply and its commit
//
// The construction is deterministic rather than a race: the first Withdraw is
// parked INSIDE journal.Append, and the second is then given unlimited time to
// finish. If the lock spans the append, it cannot; if the lock is released
// anywhere between Apply and the state assignment, it runs to completion
// immediately against a state that is about to be overwritten -- two
// withdrawals each individually valid, together overdrawing.
//
// An earlier version of this test spawned 32 concurrent withdrawals and
// checked the final balance. It passed with the lock deliberately broken:
// Go's mutex hands the lock straight back to the releasing goroutine often
// enough that the window almost never opened. A probabilistic test is not a
// gate for a deterministic defect.
func TestLedger_CriticalSection_SecondCommandCannotDecideMidCommit(t *testing.T) {
	l, j, _ := newTestLedger()
	if _, err := l.Deposit(context.Background(), "seed", "1"); err != nil {
		t.Fatalf("seed deposit: %v", err)
	}

	entered, release := j.arm()
	firstDone := make(chan struct{})
	go func() {
		defer close(firstDone)
		if _, err := l.Withdraw(context.Background(), "w1", "1"); err != nil {
			t.Errorf("first withdraw: %v", err)
		}
	}()
	<-entered // the first command is now parked inside Append, mid-transition

	secondDone := make(chan struct{})
	go func() {
		defer close(secondDone)
		if _, err := l.Withdraw(context.Background(), "w2", "1"); err != nil {
			t.Errorf("second withdraw: %v", err)
		}
	}()

	select {
	case <-secondDone:
		t.Fatal("a second command completed while the first was mid-commit: the lock " +
			"does not span decide -> journal -> commit, so both decided against the same balance")
	case <-time.After(250 * time.Millisecond):
		// Blocked, as required.
	}

	release()
	<-firstDone
	<-secondDone

	// The second withdrawal decided against the POST-first state, so it is
	// rejected and never journaled.
	if bal := l.State().Balance; bal != domain.ZeroAmount {
		t.Fatalf("final balance = %q, want %q", bal, domain.ZeroAmount)
	}
	if len(j.events) != 2 {
		t.Fatalf("journal = %d events, want 2 (the deposit and ONE admitted withdrawal)", len(j.events))
	}
}

// provenance: derived
// verifies: many concurrent withdrawals against a balance that funds only
// some of them admit exactly the affordable number
//
// This is a STRESS test, not the critical-section gate -- it passes even with
// the lock broken, because the window rarely opens (see
// TestLedger_CriticalSection_SecondCommandCannotDecideMidCommit, which is the
// gate). It is kept for the property it does cover: that the accounting
// across many admissions and rejections adds up.
func TestLedger_ConcurrentWithdrawals_AccountingAddsUp(t *testing.T) {
	l, j, n := newTestLedger()
	if _, err := l.Deposit(context.Background(), "seed", "3"); err != nil {
		t.Fatalf("seed deposit: %v", err)
	}

	const attempts = 32
	var wg sync.WaitGroup
	admitted := make([]bool, attempts)
	for i := 0; i < attempts; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			out, err := l.Withdraw(context.Background(), fmt.Sprintf("w%d", i), "1")
			if err != nil {
				t.Errorf("withdraw %d: %v", i, err)
				return
			}
			_, rejected := out.Effects[0].(domain.EffectWithdrawalRejected)
			admitted[i] = !rejected
		}(i)
	}
	wg.Wait()

	got := 0
	for _, ok := range admitted {
		if ok {
			got++
		}
	}
	if got != 3 {
		t.Fatalf("admitted withdrawals = %d, want exactly 3 (a balance of 3 funds 3)", got)
	}
	if bal := l.State().Balance; bal != domain.ZeroAmount {
		t.Fatalf("final balance = %q, want %q", bal, domain.ZeroAmount)
	}
	if len(j.events) != 4 {
		t.Fatalf("journal = %d events, want 4 (1 deposit + 3 admitted withdrawals)", len(j.events))
	}
	if n.Calls() != 4 {
		t.Fatalf("relay nudges = %d, want 4 (one per admitted event)", n.Calls())
	}
}

// provenance: derived
// verifies: idempotency at the orchestration layer -- Deposit called twice
// with the SAME eventID has the ledger's economic effect once, and the
// duplicate never reaches the log -- so the relay publishes it once too,
// without needing its own duplicate detection
func TestLedger_Deposit_SameEventIDTwiceHasEffectOnce(t *testing.T) {
	l, j, n := newTestLedger()
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
	if len(j.events) != 1 {
		t.Fatalf("journal = %d events, want 1 (the duplicate must not be appended)", len(j.events))
	}
	if n.Calls() != 1 {
		t.Fatalf("relay nudges = %d, want 1 (the duplicate must not re-notify)", n.Calls())
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
