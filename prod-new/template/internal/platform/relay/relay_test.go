package relay

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

// --- test doubles -------------------------------------------------------

type ev struct {
	pos  int64
	kind string
}

func (e ev) Position() int64 { return e.pos }

// memReader is an append-only in-memory log. batchCap, when > 0, caps how
// many events ONE read may return regardless of the limit asked for -- the
// shape of a real store that pages, and the shape that catches a relay which
// reads once and assumes it saw everything.
type memReader struct {
	mu       sync.Mutex
	events   []ev
	batchCap int
	failNext error
	reads    int
}

func (m *memReader) add(kinds ...string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, k := range kinds {
		m.events = append(m.events, ev{pos: int64(len(m.events)) + 1, kind: k})
	}
}

func (m *memReader) ReadAfter(_ context.Context, after int64, limit int) ([]ev, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.reads++
	if m.failNext != nil {
		err := m.failNext
		m.failNext = nil
		return nil, err
	}
	if m.batchCap > 0 && m.batchCap < limit {
		limit = m.batchCap
	}
	var out []ev
	for _, e := range m.events {
		if e.pos > after {
			out = append(out, e)
			if len(out) >= limit {
				break
			}
		}
	}
	return out, nil
}

func (m *memReader) Head(context.Context) (int64, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if len(m.events) == 0 {
		return 0, nil
	}
	return m.events[len(m.events)-1].pos, nil
}

type memPub struct {
	mu     sync.Mutex
	got    []Message
	failAt map[string]int // message ID -> remaining failures
}

func (p *memPub) Publish(_ context.Context, _ string, msg Message) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if n := p.failAt[msg.ID]; n > 0 {
		p.failAt[msg.ID] = n - 1
		return fmt.Errorf("pub: injected failure for %s", msg.ID)
	}
	p.got = append(p.got, msg)
	return nil
}

func (p *memPub) ids() []string {
	p.mu.Lock()
	defer p.mu.Unlock()
	out := make([]string, len(p.got))
	for i, m := range p.got {
		out[i] = m.ID
	}
	return out
}

type memCps struct {
	mu      sync.Mutex
	pos     map[string]int64
	failSet bool
}

func newMemCps() *memCps { return &memCps{pos: map[string]int64{}} }

func (c *memCps) Get(_ context.Context, name string) (int64, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.pos[name], nil
}

func (c *memCps) Set(_ context.Context, name string, p int64) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.failSet {
		return errors.New("cps: injected failure")
	}
	c.pos[name] = p
	return nil
}

// idMapper publishes one message per event, id "m<pos>". Events of kind
// "internal" map to nothing.
func idMapper(e ev) ([]Publication, error) {
	if e.kind == "internal" {
		return nil, nil
	}
	if e.kind == "bad" {
		return nil, errors.New("mapper: cannot render")
	}
	if e.kind == "noid" {
		return []Publication{{Topic: "t", Msg: Message{ID: ""}}}, nil
	}
	return []Publication{{Topic: "t", Msg: Message{ID: fmt.Sprintf("m%d", e.pos)}}}, nil
}

func newTestRelay(t *testing.T, r *memReader, opts Options) (*Relay[ev], *memPub, *memCps) {
	t.Helper()
	p := &memPub{failAt: map[string]int{}}
	c := newMemCps()
	rel, err := New[ev](r, c, idMapper, p, nil, opts)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	return rel, p, c
}

// --- tests --------------------------------------------------------------

// provenance: derived
// verifies: relay.New rejects a relay missing any collaborator that could
// otherwise let it advance past events silently
func TestNew_RejectsMissingCollaborators(t *testing.T) {
	r, c, p := &memReader{}, newMemCps(), &memPub{failAt: map[string]int{}}
	cases := map[string]func() (*Relay[ev], error){
		"no reader":    func() (*Relay[ev], error) { return New[ev](nil, c, idMapper, p, nil, Options{}) },
		"no cps":       func() (*Relay[ev], error) { return New[ev](r, nil, idMapper, p, nil, Options{}) },
		"no mapper":    func() (*Relay[ev], error) { return New[ev](r, c, nil, p, nil, Options{}) },
		"no publisher": func() (*Relay[ev], error) { return New[ev](r, c, idMapper, nil, nil, Options{}) },
	}
	for name, build := range cases {
		if _, err := build(); err == nil {
			t.Errorf("%s: New succeeded, want an error", name)
		}
	}
	// A nil Leader is the ONE legitimate omission: single-replica is a real
	// deployment, so it defaults rather than failing.
	if _, err := New[ev](r, c, idMapper, p, nil, Options{}); err != nil {
		t.Fatalf("New with a nil Leader: %v", err)
	}
}

// provenance: derived
// verifies: the relay publishes every event exactly once, in log order, and
// leaves the checkpoint at the head
func TestRelay_PublishesInOrderAndCheckpointsAtHead(t *testing.T) {
	r := &memReader{}
	r.add("a", "b", "c")
	rel, p, c := newTestRelay(t, r, Options{Name: "rl"})
	if err := rel.RunToEnd(context.Background()); err != nil {
		t.Fatalf("RunToEnd: %v", err)
	}
	if got, want := p.ids(), []string{"m1", "m2", "m3"}; fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("published %v, want %v", got, want)
	}
	if pos, _ := c.Get(context.Background(), "rl"); pos != 3 {
		t.Fatalf("checkpoint = %d, want 3", pos)
	}
	if lag, err := rel.Lag(context.Background()); err != nil || lag != 0 {
		t.Fatalf("Lag = %d, %v; want 0, nil", lag, err)
	}
	// The counters are the operator's view of the same run. They exist so a
	// stalled relay is distinguishable from an idle one: zero batches with a
	// non-zero lag is a relay that is not reading, which no lag value alone
	// can tell you.
	if rel.Published() != 3 {
		t.Fatalf("Published = %d, want 3", rel.Published())
	}
	if rel.Batches() != 1 {
		t.Fatalf("Batches = %d, want 1", rel.Batches())
	}
	if rel.Skipped() != 0 {
		t.Fatalf("Skipped = %d, want 0", rel.Skipped())
	}
}

// provenance: derived
// verifies: a reader that pages must be CHASED to the head -- the relay keeps
// draining until a read comes back empty, rather than stopping after one
// batch
//
// This is the case that a single-read relay passes only by accident: with
// batchCap 1 and three events, a relay that reads once delivers one message
// and reports success. clc-go's store contract suite records that exactly
// this shape once masked a fence bug losing ~8% of events under load.
func TestRelay_SmallBatchesAreChasedToTheHead(t *testing.T) {
	r := &memReader{batchCap: 1}
	r.add("a", "b", "c", "d", "e")
	rel, p, c := newTestRelay(t, r, Options{Name: "rl", Batch: 1})
	if err := rel.RunToEnd(context.Background()); err != nil {
		t.Fatalf("RunToEnd: %v", err)
	}
	if got := p.ids(); len(got) != 5 {
		t.Fatalf("published %v (%d), want all 5", got, len(got))
	}
	if pos, _ := c.Get(context.Background(), "rl"); pos != 5 {
		t.Fatalf("checkpoint = %d, want 5", pos)
	}
	// Five single-event batches, not one: the relay went back for more each
	// time rather than assuming the first read saw everything.
	if rel.Batches() != 5 {
		t.Fatalf("Batches = %d, want 5 (one per paged read)", rel.Batches())
	}
}

// provenance: derived
// verifies: a publish failure holds the checkpoint, so the event is
// REDELIVERED rather than lost -- and the redelivery reuses the SAME message
// ID, which is the only thing that lets a consumer recognise it
func TestRelay_PublishFailure_HoldsCheckpointAndRedeliversTheSameID(t *testing.T) {
	r := &memReader{}
	r.add("a", "b", "c")
	rel, p, c := newTestRelay(t, r, Options{Name: "rl"})
	p.failAt["m2"] = 1

	if err := rel.RunToEnd(context.Background()); err == nil {
		t.Fatal("RunToEnd succeeded despite a publish failure")
	}
	if pos, _ := c.Get(context.Background(), "rl"); pos != 1 {
		t.Fatalf("checkpoint = %d, want 1 (held at the last SUCCESSFUL publish)", pos)
	}
	if got, want := p.ids(), []string{"m1"}; fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("published %v, want %v", got, want)
	}

	// Resume: m2 must come back with the same identity, and m3 must follow.
	if err := rel.RunToEnd(context.Background()); err != nil {
		t.Fatalf("resumed RunToEnd: %v", err)
	}
	if got, want := p.ids(), []string{"m1", "m2", "m3"}; fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("after resume published %v, want %v", got, want)
	}
}

// provenance: derived
// verifies: a checkpoint write failure NEVER loses the event -- the position
// stays put and the message is redelivered (the at-least-once half of the
// contract, and the reason Msg.ID is stable)
func TestRelay_CheckpointFailure_RedeliversRatherThanSkips(t *testing.T) {
	r := &memReader{}
	r.add("a", "b")
	rel, p, c := newTestRelay(t, r, Options{Name: "rl"})
	c.failSet = true

	if err := rel.RunToEnd(context.Background()); err == nil {
		t.Fatal("RunToEnd succeeded despite a checkpoint failure")
	}
	if got, want := p.ids(), []string{"m1"}; fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("published %v, want %v", got, want)
	}
	c.failSet = false
	if err := rel.RunToEnd(context.Background()); err != nil {
		t.Fatalf("resumed: %v", err)
	}
	// m1 published twice: a DUPLICATE, which consumers deduplicate on ID.
	// The property under test is that nothing was LOST, not that nothing was
	// repeated -- exactly-once delivery does not exist.
	if got, want := p.ids(), []string{"m1", "m1", "m2"}; fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("published %v, want %v (a duplicate, never a gap)", got, want)
	}
}

// provenance: derived
// verifies: an event that maps to nothing still ADVANCES the checkpoint, so
// one internal-only fact cannot stall delivery of everything behind it
func TestRelay_UnpublishedEventStillAdvancesTheCheckpoint(t *testing.T) {
	r := &memReader{}
	// The internal-only events are at the HEAD of the log on purpose. A
	// skipped event in the MIDDLE is advanced past for free by the next
	// published one, so a relay that never checkpoints skipped events still
	// looks correct there. Only a skipped event with nothing after it
	// exposes the stall -- and a stalled checkpoint at the head means every
	// restart re-reads the same tail forever while lag never reaches zero.
	r.add("internal", "a", "internal", "internal")
	rel, p, c := newTestRelay(t, r, Options{Name: "rl"})
	if err := rel.RunToEnd(context.Background()); err != nil {
		t.Fatalf("RunToEnd: %v", err)
	}
	if got, want := p.ids(), []string{"m2"}; fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("published %v, want %v", got, want)
	}
	if pos, _ := c.Get(context.Background(), "rl"); pos != 4 {
		t.Fatalf("checkpoint = %d, want 4 -- the trailing internal-only events must be "+
			"advanced past, or the relay re-reads them on every wake and lag never reaches 0", pos)
	}
	if lag, err := rel.Lag(context.Background()); err != nil || lag != 0 {
		t.Fatalf("Lag = %d, %v; want 0, nil (a log with nothing left to publish is caught up)", lag, err)
	}
	if rel.Skipped() != 3 {
		t.Fatalf("Skipped = %d, want 3", rel.Skipped())
	}
}

// provenance: derived
// verifies: a mapper error STOPS the relay with the checkpoint held -- the
// event is neither published wrong nor silently skipped
func TestRelay_MapperError_StopsWithTheCheckpointHeld(t *testing.T) {
	r := &memReader{}
	r.add("a", "bad", "c")
	rel, _, c := newTestRelay(t, r, Options{Name: "rl"})
	err := rel.RunToEnd(context.Background())
	if err == nil {
		t.Fatal("RunToEnd succeeded despite a mapper error")
	}
	if pos, _ := c.Get(context.Background(), "rl"); pos != 1 {
		t.Fatalf("checkpoint = %d, want 1 (held at the last good event)", pos)
	}
}

// provenance: derived
// verifies: a message with an empty ID is REFUSED rather than published --
// an un-deduplicatable message is worse than a stopped relay, because the
// consumer cannot tell a redelivery from a new fact
func TestRelay_EmptyMessageIDIsRefused(t *testing.T) {
	r := &memReader{}
	r.add("noid")
	rel, p, c := newTestRelay(t, r, Options{Name: "rl"})
	if err := rel.RunToEnd(context.Background()); err == nil {
		t.Fatal("RunToEnd published a message with no ID")
	}
	if len(p.ids()) != 0 {
		t.Fatalf("published %v, want nothing", p.ids())
	}
	if pos, _ := c.Get(context.Background(), "rl"); pos != 0 {
		t.Fatalf("checkpoint = %d, want 0", pos)
	}
}

// provenance: derived
// verifies: a relay resumed from a stored checkpoint republishes NOTHING
// before it -- restart is not a flood
func TestRelay_ResumesFromTheStoredCheckpoint(t *testing.T) {
	r := &memReader{}
	r.add("a", "b", "c")
	p := &memPub{failAt: map[string]int{}}
	c := newMemCps()
	c.pos["rl"] = 2
	rel, err := New[ev](r, c, idMapper, p, nil, Options{Name: "rl"})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if err := rel.RunToEnd(context.Background()); err != nil {
		t.Fatalf("RunToEnd: %v", err)
	}
	if got, want := p.ids(), []string{"m3"}; fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("published %v, want only %v", got, want)
	}
}

// provenance: derived
// verifies: a read failure surfaces instead of being mistaken for "no events"
func TestRelay_ReadFailureSurfaces(t *testing.T) {
	r := &memReader{}
	r.add("a")
	r.failNext = errors.New("store down")
	rel, _, _ := newTestRelay(t, r, Options{Name: "rl"})
	if err := rel.RunToEnd(context.Background()); err == nil {
		t.Fatal("RunToEnd treated a read failure as an empty log")
	}
}

// provenance: derived
// verifies: Notify never blocks, whether or not anyone is draining -- the
// write path calls it while holding nothing, and a blocking nudge would put
// the relay back in front of a command
func TestRelay_NotifyNeverBlocks(t *testing.T) {
	rel, _, _ := newTestRelay(t, &memReader{}, Options{Name: "rl"})
	done := make(chan struct{})
	go func() {
		for i := 0; i < 10_000; i++ {
			rel.Notify()
		}
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("Notify blocked")
	}
}

// provenance: derived
// verifies: Run wakes on Notify rather than waiting out the idle interval
func TestRelay_RunWakesOnNotify(t *testing.T) {
	r := &memReader{}
	rel, p, _ := newTestRelay(t, r, Options{Name: "rl", Idle: time.Hour})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	errc := make(chan error, 1)
	go func() { errc <- rel.Run(ctx) }()

	r.add("a")
	rel.Notify()

	deadline := time.After(5 * time.Second)
	for len(p.ids()) == 0 {
		select {
		case <-deadline:
			t.Fatal("Run did not deliver within 5s despite a Notify (idle is 1h, so it never woke)")
		case <-time.After(2 * time.Millisecond):
		}
	}
	cancel()
	if err := <-errc; err != nil {
		t.Fatalf("Run: %v", err)
	}
}

// provenance: derived
// verifies: two concurrent Run calls on one relay are refused -- a second
// runner would publish everything twice
func TestRelay_ConcurrentRunIsRefused(t *testing.T) {
	rel, _, _ := newTestRelay(t, &memReader{}, Options{Name: "rl", Idle: time.Hour})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	errc := make(chan error, 1)
	go func() { errc <- rel.Run(ctx) }()

	var err error
	for i := 0; i < 500; i++ {
		if err = rel.RunToEnd(context.Background()); errors.Is(err, ErrRunning) {
			break
		}
		time.Sleep(2 * time.Millisecond)
	}
	if !errors.Is(err, ErrRunning) {
		t.Fatalf("second run returned %v, want ErrRunning", err)
	}
	cancel()
	<-errc
}

// lossyLeader loses the slot on the first Acquire.
type lossyLeader struct{ ch chan struct{} }

func (l lossyLeader) Acquire(context.Context) (func(), <-chan struct{}, error) {
	close(l.ch)
	return func() {}, l.ch, nil
}

// provenance: derived
// verifies: losing leadership stops the relay with ErrLeadershipLost rather
// than continuing to publish alongside the new leader
func TestRelay_LeadershipLostStopsTheRelay(t *testing.T) {
	p := &memPub{failAt: map[string]int{}}
	rel, err := New[ev](&memReader{}, newMemCps(), idMapper, p, lossyLeader{ch: make(chan struct{})}, Options{Name: "rl", Idle: time.Hour})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if err := rel.Run(context.Background()); !errors.Is(err, ErrLeadershipLost) {
		t.Fatalf("Run = %v, want ErrLeadershipLost", err)
	}
}

type failLeader struct{}

func (failLeader) Acquire(context.Context) (func(), <-chan struct{}, error) {
	return nil, nil, errors.New("no quorum")
}

// provenance: derived
// verifies: a leader that cannot be acquired is an error, not a silent
// single-replica fallback
func TestRelay_LeaderAcquireFailureIsAnError(t *testing.T) {
	rel, err := New[ev](&memReader{}, newMemCps(), idMapper, &memPub{failAt: map[string]int{}}, failLeader{}, Options{Name: "rl"})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if err := rel.Run(context.Background()); err == nil {
		t.Fatal("Run succeeded despite a leadership acquisition failure")
	}
}

// provenance: derived
// verifies: NopLeader acquires immediately and never reports loss
func TestNopLeader_AcquiresAndNeverLoses(t *testing.T) {
	release, lost, err := NopLeader().Acquire(context.Background())
	if err != nil {
		t.Fatalf("Acquire: %v", err)
	}
	if release == nil {
		t.Fatal("Acquire returned a nil release func; every caller defers it")
	}
	release()
	select {
	case <-lost:
		t.Fatal("NopLeader reported leadership loss")
	default:
	}
}

// provenance: derived
// verifies: Lag reports how far behind the head the relay is, and never goes
// negative when the checkpoint is ahead of a truncated log
func TestRelay_LagReportsDistanceFromHead(t *testing.T) {
	r := &memReader{}
	r.add("a", "b", "c")
	p := &memPub{failAt: map[string]int{}}
	c := newMemCps()
	rel, err := New[ev](r, c, idMapper, p, nil, Options{Name: "rl"})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if lag, _ := rel.Lag(context.Background()); lag != 3 {
		t.Fatalf("Lag = %d, want 3 before draining", lag)
	}
	if err := rel.RunToEnd(context.Background()); err != nil {
		t.Fatalf("RunToEnd: %v", err)
	}
	if lag, _ := rel.Lag(context.Background()); lag != 0 {
		t.Fatalf("Lag = %d, want 0 after draining", lag)
	}
	c.pos["rl"] = 99
	if lag, _ := rel.Lag(context.Background()); lag != 0 {
		t.Fatalf("Lag = %d, want 0 (never negative) when the checkpoint is ahead of the head", lag)
	}
}

// provenance: derived
// verifies: Options defaults are applied, so a zero Options is a working
// relay rather than one with a zero batch that reads nothing forever
func TestOptions_ZeroValueIsUsable(t *testing.T) {
	r := &memReader{}
	r.add("a")
	rel, p, _ := newTestRelay(t, r, Options{})
	if err := rel.RunToEnd(context.Background()); err != nil {
		t.Fatalf("RunToEnd: %v", err)
	}
	if len(p.ids()) != 1 {
		t.Fatalf("published %v, want 1 message with zero-value Options", p.ids())
	}
}

// --- FileCheckpoints ----------------------------------------------------

// provenance: derived
// verifies: a checkpoint survives a reopen, which is the whole point of it
// being durable
func TestFileCheckpoints_RoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "cp.json")
	c, err := OpenCheckpoints(path)
	if err != nil {
		t.Fatalf("OpenCheckpoints: %v", err)
	}
	if err := c.Set(context.Background(), "rl", 7); err != nil {
		t.Fatalf("Set: %v", err)
	}
	reopened, err := OpenCheckpoints(path)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	if pos, _ := reopened.Get(context.Background(), "rl"); pos != 7 {
		t.Fatalf("reopened position = %d, want 7", pos)
	}
}

// provenance: derived
// verifies: a missing file is position zero (a service that never relayed),
// but a CORRUPT file is an error -- reading corruption as zero would
// republish the entire log while looking like a clean boot
func TestFileCheckpoints_MissingIsZeroButCorruptIsAnError(t *testing.T) {
	dir := t.TempDir()
	c, err := OpenCheckpoints(filepath.Join(dir, "absent.json"))
	if err != nil {
		t.Fatalf("missing file: %v", err)
	}
	if pos, _ := c.Get(context.Background(), "rl"); pos != 0 {
		t.Fatalf("missing file position = %d, want 0", pos)
	}

	bad := filepath.Join(dir, "bad.json")
	if err := os.WriteFile(bad, []byte(`{"rl": `), 0o600); err != nil {
		t.Fatalf("write: %v", err)
	}
	if _, err := OpenCheckpoints(bad); err == nil {
		t.Fatal("a corrupt checkpoint file opened cleanly, which would republish all of history")
	}

	empty := filepath.Join(dir, "empty.json")
	if err := os.WriteFile(empty, []byte("  \n"), 0o600); err != nil {
		t.Fatalf("write: %v", err)
	}
	if _, err := OpenCheckpoints(empty); err != nil {
		t.Fatalf("an empty (never-written) file should open as zero: %v", err)
	}
}

// provenance: derived
// verifies: a checkpoint refuses to move BACKWARDS -- honouring a lower
// position would silently republish everything in between
func TestFileCheckpoints_RefusesToMoveBackwards(t *testing.T) {
	c, err := OpenCheckpoints(filepath.Join(t.TempDir(), "cp.json"))
	if err != nil {
		t.Fatalf("OpenCheckpoints: %v", err)
	}
	ctx := context.Background()
	if err := c.Set(ctx, "rl", 10); err != nil {
		t.Fatalf("Set: %v", err)
	}
	if err := c.Set(ctx, "rl", 4); err == nil {
		t.Fatal("Set moved the checkpoint backwards")
	}
	if pos, _ := c.Get(ctx, "rl"); pos != 10 {
		t.Fatalf("position = %d, want 10 (unchanged by the refused write)", pos)
	}
	// Re-setting the SAME position must be allowed: a relay that republishes
	// a batch after a crash legitimately re-writes the position it already
	// has, and rejecting that would turn a normal recovery into an error.
	if err := c.Set(ctx, "rl", 10); err != nil {
		t.Fatalf("re-Set of the same position: %v", err)
	}
}

// provenance: derived
// verifies: a failed durable write ROLLS BACK the in-memory position, so the
// store never claims a durability the disk does not have
func TestFileCheckpoints_FailedWriteRollsBackInMemory(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "sub", "cp.json") // parent does not exist
	c, err := OpenCheckpoints(path)
	if err != nil {
		t.Fatalf("OpenCheckpoints: %v", err)
	}
	ctx := context.Background()
	if err := c.Set(ctx, "rl", 5); err == nil {
		t.Fatal("Set succeeded with an unwritable path")
	}
	if pos, _ := c.Get(ctx, "rl"); pos != 0 {
		t.Fatalf("in-memory position = %d after a failed write, want 0 -- a relay "+
			"believing it checkpointed would not republish, losing every event in between", pos)
	}
}

// provenance: derived
// verifies: concurrent Sets across names are serialised and all survive
func TestFileCheckpoints_ConcurrentSetsAllPersist(t *testing.T) {
	path := filepath.Join(t.TempDir(), "cp.json")
	c, err := OpenCheckpoints(path)
	if err != nil {
		t.Fatalf("OpenCheckpoints: %v", err)
	}
	var wg sync.WaitGroup
	for i := 0; i < 16; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			if err := c.Set(context.Background(), fmt.Sprintf("rl%d", i), int64(i+1)); err != nil {
				t.Errorf("Set %d: %v", i, err)
			}
		}(i)
	}
	wg.Wait()
	reopened, err := OpenCheckpoints(path)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	for i := 0; i < 16; i++ {
		if pos, _ := reopened.Get(context.Background(), fmt.Sprintf("rl%d", i)); pos != int64(i+1) {
			t.Fatalf("rl%d = %d, want %d", i, pos, i+1)
		}
	}
}
