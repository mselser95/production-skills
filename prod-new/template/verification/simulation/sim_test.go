// Package simulation is this service's STAGE-1 deterministic simulation
// harness: ONE seeded, reproducible schedule of ~500 operations and injected
// faults, driven through the REAL app-layer orchestrator
// (internal/app.Ledger) with the deterministic fakes this template already
// uses, asserting the ratified invariants after every single step.
//
// # Where the shape comes from
//
// FoundationDB's simulation testing -- Zhou et al., "FoundationDB: A
// Distributed, Unbundled Transactional Key-Value Store", SIGMOD 2021 -- is
// the source. FDB wrote the simulator BEFORE the database: the whole system
// runs inside a single-threaded, deterministic environment where time, task
// scheduling, disk and network are supplied by the simulator, and faults are
// injected from a pseudo-random schedule derived from one seed. The property
// that makes that worth the cost is not "more tests" -- it is that a failure
// is REPRODUCIBLE FROM ITS SEED ALONE. A red run hands you the input that
// produced it, so a bug found once is a bug you can watch again on demand,
// and the fix is provable by the same seed going green.
//
// That property is the entire reason this file exists, and it is why every
// failure message below carries the seed and the step index, and why the
// harness prints its reproduce command on failure. A randomized test that
// cannot tell you how to see the failure again is a rumor, not a finding.
//
// # What stage 1 IS
//
//   - Single process, single goroutine. The schedule is executed in order,
//     start to finish, by the test's own goroutine.
//   - APP LAYER ONLY: internal/app.Ledger driven through its real public
//     command surface (Deposit/Withdraw), over the injected Clock,
//     IDGenerator and EventJournal ports -- the same three deterministic
//     fakes internal/app's own tests inject (see ledger_test.go's
//     newTestLedger). Nothing here reaches into the package's internals.
//   - Two injected faults, and they are the two the app layer can ACTUALLY
//     experience through those ports: a durable-append failure, and a
//     duplicate delivery of an already-applied event.
//   - Restarts are real state-replay restarts: the state is rebuilt from the
//     journal with internal/platform/eventlog.Rebuild -- the composition
//     root's own boot fold, not a re-implementation of it -- and a fresh
//     Ledger is built over the surviving log.
//
// # What stage 1 deliberately IS NOT
//
// There is NO simulated network, NO simulated disk, and NO simulated
// scheduler. Nothing here reorders, delays, partitions or duplicates
// anything at the transport or storage layer, because none of those things
// exist in this harness: it does not drive a process boundary. STAGE 2 --
// the simulated environment that would let this become a real DST rig --
// DOES NOT EXIST. It is not stubbed, not partially wired, and not hidden
// behind a flag. Saying so plainly is load-bearing: "we have deterministic
// simulation" is exactly the sentence a stage-1 harness makes people say,
// and it is false in the way that matters (concurrency and partial failure
// across processes are what simulation is FOR).
//
// Amount-shape edges (malformed decimals, precision, overflow) are also out
// of scope here on purpose. This harness varies the SCHEDULE; the parser is
// internal/domain's fuzz and property territory (FuzzParseAmount,
// TestPropertyLedgerConservation_RandomEventSequences), which explores a
// space this one would only sample badly.
//
// # The fault classes, counted against a denominator
//
// The two faults above are not the author's imagination: the standard's
// denominator for fault coverage is the capability-class checklist
// (tier-policy.yaml, capability_classes), and this scaffold's one declared
// capability is external_effect, whose checklist has nine scenarios. Two of
// them have an app-layer analog this harness expresses --
// crash_between_decision_and_effect (the append failure plus the restart
// that follows it) and duplicate_response (redelivery, seen from the inbound
// side). The other seven -- rejected, timeout_before_acceptance,
// timeout_after_acceptance, malformed_response, unavailable, extreme_latency,
// retry_on_unknown_state -- live at the ADAPTER boundary this harness does
// not drive, and are covered by internal/adapter/out/store's conformance kit
// instead. Naming the ratio (2 of 9, with the other 7 covered elsewhere) is
// the point: a fault schedule with no denominator reports coverage against
// what its author happened to think of.
//
// # Why advisory (dimension 27), and the three vacuous forms
//
// Dimension 27 is ADVISORY in the standard: no probe row demands that a repo
// ship a simulation package, and no required check fails for its absence.
// The reason is that the gate would be the vacuous form. A required row
// buys a directory named `verification/simulation/` in every repo the day it
// lands -- and directories are cheap to produce and impossible to falsify
// from outside. Simulation earns a gate the way every other lane in this
// repo earned one: after the harness has CAUGHT something, with the seed
// that caught it recorded, at which point the gate is protecting a proven
// mechanism instead of mandating a hopeful one.
//
// The second vacuous form is inside the harness rather than around it: a
// schedule that drifts into "500 deposits" still asserts conservation, still
// passes, and proves nothing about withdrawal rejection, idempotency,
// append failure or replay. That is what the schedule-adequacy block at the
// end of TestSimulation_SeededFaultSchedule exists to prevent, in the same
// spirit as internal/domain/ledger_property_test.go's generator-adequacy
// floors -- and it is asserted, never hoped for.
//
// The third is a SEED THAT DOES NOT REPRODUCE, which would quietly undo the
// only reason to prefer a seeded schedule over a random one.
// TestSimulation_SeedReproduces runs one seed twice and compares the decision
// traces byte for byte. That check is not decoration either: replacing the
// injected id generator with time.Now().UnixNano() leaves
// TestSimulation_SeededFaultSchedule GREEN -- the invariants genuinely still
// hold -- and turns the reproducibility test red at trace line 15 (measured
// 2026-08-27, and again with the log digest removed from the trace, which is
// what makes that field load-bearing rather than ornamental).
//
// Being advisory as a DIMENSION does not make this file's fixed-seed run
// optional: with SIM_SEED unset the schedule is a pure function of
// defaultSeed, so this test is exactly as deterministic as any other test in
// the module and it runs in the ordinary `go test ./...` lane. A red here is
// a real, reproducible defect, not a flake. What stays out of the blocking
// lane is the RANDOM-seed sweep (`SIM_SEED=$RANDOM make sim`), whose red is
// a finding to be minimized into regressions/, not a reason to stop a merge
// on a schedule nobody has seen before.
//
// # Reuse, and the one thing that could not be reused
//
// The clock/ids fakes are the shapes internal/app's ledger_test.go injects,
// and eventlog.Rebuild is the real boot fold. simJournal below is a
// re-declaration of that package's fakeJournal rather than a reuse of it,
// for a mechanical reason and not a stylistic one: Go test doubles live in
// _test.go files and do not cross package boundaries, so there is nothing to
// import. It is kept deliberately smaller than the original -- no mutex, no
// gate channels -- and that absence is a statement: stage 1 has no
// concurrency for a lock to protect.
package simulation

import (
	"context"
	"errors"
	"fmt"
	"hash"
	"hash/fnv"
	"math/big"
	"math/rand"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/<OWNER>/<SERVICE>/internal/app"
	"github.com/<OWNER>/<SERVICE>/internal/domain"
	"github.com/<OWNER>/<SERVICE>/internal/platform/eventlog"
)

// defaultSeed is the schedule every unattended run executes. It is a
// constant, not a timestamp: a harness that seeds itself from the clock
// turns every CI run into a different test, so a red run cannot be told from
// a newly-drawn schedule and "it passed on rerun" becomes a valid-looking
// sentence. Sweeping other seeds is what SIM_SEED is for.
const defaultSeed = 20260827

// scheduleLength is how many operations one run executes. 500 is enough for
// restarts to land on top of hundreds of accumulated events (so replay is
// folding real history, not three records) while keeping the whole run in
// the milliseconds a `go test ./...` lane can afford.
const scheduleLength = 500

// simEpoch is the harness's logical time origin. The injected clock advances
// one second per step from here, so a recorded violation timestamp names the
// step that produced it. internal/app reads the clock ONLY when an invariant
// check fails, which is precisely when a meaningful timestamp is worth
// having.
var simEpoch = time.Unix(1_700_000_000, 0).UTC()

// errInjectedAppend is the durable-append failure this harness injects. It
// is a plain error because that is all the EventJournal port promises: the
// app layer's contract is "the append failed", and a harness that injected a
// richer, recognizable error type would be testing a path production never
// takes.
var errInjectedAppend = errors.New("simulation: injected durable-append failure")

// simJournal is the in-memory EventJournal this harness appends to -- the
// durable log's stand-in, and the thing a restart replays. See the package
// doc for why it is a re-declaration of internal/app's fakeJournal rather
// than an import of it, and why it carries no mutex.
type simJournal struct {
	events   []domain.Event
	failNext bool

	// digest is a rolling FNV-1a hash of every record this journal has
	// accepted, in order, over the id AND the type AND the amount. The
	// per-step trace carries it (see runSchedule) so the reproducibility
	// check compares what was actually written, not a summary of it: counts
	// alone compare equal between two runs that wrote different events, which
	// is exactly what a nondeterministic id generator produces.
	//
	// It covers the DURABLE record only. A rejected command writes nothing,
	// so nondeterminism confined to ids that never reach the log is invisible
	// here -- and is also invisible to the ledger, which is the argument for
	// not paying more to see it.
	digest hash.Hash32
}

func (j *simJournal) Append(_ context.Context, e domain.Event) error {
	if j.failNext {
		j.failNext = false
		return errInjectedAppend
	}
	j.events = append(j.events, e)
	// Hash.Write never returns an error (hash.Hash's contract says so
	// explicitly), which is why this one is dropped rather than checked.
	_, _ = fmt.Fprintf(j.digest, "%s|%s|%s\n", e.ID, e.Type, e.Amount)
	return nil
}

// opKind is the closed set of things one scheduled step can do. Deposits and
// withdrawals are the workload; the other three are the faults and the
// recovery event the workload is interleaved with.
type opKind int

const (
	opDeposit opKind = iota
	opWithdraw
	// opDuplicateDelivery redelivers an event that was already admitted --
	// the at-least-once delivery fault, expressed at the only layer that can
	// defend against it (domain.Apply's idempotency guard, reached through
	// the app's real command path).
	opDuplicateDelivery
	// opAppendFailure fails the next durable append underneath a command --
	// the storage fault the app layer's csApplied -> csLogged transition
	// exists to survive.
	opAppendFailure
	// opRestart rebuilds state from the surviving journal and continues on a
	// fresh Ledger -- a process restart, minus the process.
	opRestart
)

func (k opKind) String() string {
	switch k {
	case opDeposit:
		return "deposit"
	case opWithdraw:
		return "withdraw"
	case opDuplicateDelivery:
		return "duplicate-delivery"
	case opAppendFailure:
		return "append-failure"
	case opRestart:
		return "restart"
	default:
		return "unknown"
	}
}

// step is one scheduled operation. Every field is drawn from the seeded
// generator BEFORE execution begins (see newSchedule), so the schedule is a
// pure function of the seed and could be printed, diffed or shrunk without
// running anything.
type step struct {
	kind  opKind
	units int64   // amount, in Scale-shifted integer units
	mint  bool    // let the injected IDGenerator mint the event id
	pick  float64 // duplicate-delivery: which already-admitted event is redelivered
	// overdraft turns a withdrawal into a DELIBERATE attempt to outrun the
	// balance: the amount is derived at execution time from the balance the
	// ledger actually holds, so the attempt is guaranteed to be rejected.
	// See newSchedule for why this is drawn rather than hoped for.
	overdraft bool
}

// newSchedule derives the whole run from rng up front.
//
// The weights make the interesting outcomes frequent rather than lucky:
// duplicates and append failures are common enough that a 500-step run
// cannot miss them, and restarts are rare enough that each one replays a
// long log. The schedule-adequacy block at the end of the test is what turns
// that claim into something checked rather than something asserted here.
//
// The overdraft draw is there because the first version of this generator
// did hope. Withdrawals simply drew from a wider amount range than deposits
// (1..8000 against 1..5000), on the argument that this would keep
// insufficient-balance rejections continuous. It does not: deposits outnumber
// withdrawals, so the balance drifts up and out of reach of the widest
// withdrawal, and rejections become an early-run phenomenon whose count is
// pure luck. Measured across six seeds before this branch existed: 47, 35,
// 22, 18, 18 -- and 2, on seed 42, which failed the adequacy floor. A
// deliberate overdraft (amount = current balance + 1 + noise) makes the
// rejection branch a scheduled event instead of a side effect of drift.
func newSchedule(rng *rand.Rand, n int) []step {
	steps := make([]step, 0, n)
	for i := 0; i < n; i++ {
		var s step
		switch roll := rng.Float64(); {
		case roll < 0.40:
			s.kind = opDeposit
			s.units = int64(1 + rng.Intn(5_000))
			s.mint = rng.Float64() < 0.25 // exercise the injected id port, not only caller-supplied ids
		case roll < 0.75:
			s.kind = opWithdraw
			s.units = int64(1 + rng.Intn(8_000))
			s.overdraft = rng.Float64() < 0.25
		case roll < 0.87:
			s.kind = opDuplicateDelivery
			s.pick = rng.Float64()
		case roll < 0.95:
			s.kind = opAppendFailure
			s.units = int64(1 + rng.Intn(5_000))
		default:
			s.kind = opRestart
		}
		steps = append(steps, s)
	}
	return steps
}

// simulation holds the running world: the ledger under test, the log behind
// it, and the harness's OWN bookkeeping -- deliberately independent of the
// ledger's, so the invariant checks compare two computations rather than
// asking the ledger to confirm itself.
type simulation struct {
	t     *testing.T
	seed  int64
	steps []step
	index int

	ledger  *app.Ledger
	journal *simJournal

	// expected is the independent conservation tracker, in Scale-shifted
	// integer units and maintained with math/big -- never by reading the
	// ledger's own balance back. This is the same discipline
	// verification/ratified/invariants_test.go applies to the ratified
	// units_conserved invariant.
	expected *big.Int

	// admitted is every event the ledger has accepted and made durable, in
	// order, kept so a duplicate-delivery step can redeliver a byte-identical
	// event rather than an invented one.
	admitted []domain.Event

	// clockFn and idsFn are the injected ports, held so a restart rebuilds
	// the Ledger over the SAME deterministic fakes -- a restart that handed
	// the new process fresh ports would be testing a different world than the
	// one that crashed.
	clockFn func() time.Time
	idsFn   func() string

	// trace is one line per executed step: the decision the world reached,
	// recorded so a second run of the same seed can be compared to this one
	// byte for byte (TestSimulation_SeedReproduces). It is the harness's own
	// answer to the third vacuous form the package doc names -- a seed that
	// does not reproduce turns every failure back into a story.
	trace []string

	nudges  int
	nextID  int
	minted  int
	clockAt time.Time

	// schedule-adequacy counters -- see the assertions at the end of the test.
	deposits    int
	withdrawals int
	rejections  int
	duplicates  int
	faults      int
	restarts    int
	balances    map[string]bool
}

// where prefixes every failure with the two facts that make it actionable:
// the seed that produced this schedule, and the position in it.
func (s *simulation) where() string {
	kind := "setup"
	if s.index < len(s.steps) {
		kind = s.steps[s.index].kind.String()
	}
	return fmt.Sprintf("seed=%d step=%d/%d %s", s.seed, s.index+1, len(s.steps), kind)
}

func (s *simulation) freshID() string {
	s.nextID++
	return fmt.Sprintf("sim-%04d", s.nextID)
}

// newSimulation builds the world with the three deterministic fakes: an
// injected clock that advances with the schedule, an injected id generator
// that counts instead of randomizing, and the in-memory journal above. The
// notifier counts relay nudges, which the per-step invariant check compares
// against the durable log's length.
func newSimulation(t *testing.T, seed int64, steps []step) *simulation {
	t.Helper()
	s := &simulation{
		t:        t,
		seed:     seed,
		steps:    steps,
		journal:  &simJournal{digest: fnv.New32a()},
		expected: new(big.Int),
		clockAt:  simEpoch,
		balances: map[string]bool{},
	}
	s.clockFn = func() time.Time { return s.clockAt }
	s.idsFn = func() string {
		s.minted++
		return mintedIDPrefix + fmt.Sprintf("%04d", s.minted)
	}
	s.ledger = app.NewLedger(domain.NewState(), s.journal, func() { s.nudges++ }, s.clockFn, s.idsFn)
	return s
}

// mintedIDPrefix marks an id that came from the INJECTED generator rather
// than from the harness's caller-supplied sequence, so a step that asked for
// a minted id can prove the port actually produced it instead of assuming so.
const mintedIDPrefix = "sim-minted-"

// provenance: derived
// verifies: units_conserved and duplicate_event_single_effect (both ratified
// 2026-08-17, see verification/ratified/invariants_test.go) hold at EVERY
// step of a seeded schedule of workload and injected faults driven through
// the real app-layer orchestrator, including across state-replay restarts.
//
// This test is derived, not ratified: the invariants it asserts are the
// ratified ones, but the schedule that exercises them is generated here and
// carries no ratification package of its own.
func TestSimulation_SeededFaultSchedule(t *testing.T) {
	seed := resolveSeed(t)
	t.Logf("simulation seed = %d (override with SIM_SEED)", seed)
	s := runSchedule(t, seed)

	// The final full replay: the whole surviving log folded from genesis must
	// reproduce the state the process holds in memory. Every restart already
	// checked this against the log as it stood then; this one checks it
	// against the log as it ends, including everything appended after the
	// last restart.
	s.assertReplayMatchesMemory("final")

	assertScheduleAdequacy(s)
}

// provenance: derived
// verifies: the seed REPRODUCES -- two runs of one seed take byte-identical
// decision traces.
//
// This is the third vacuous form the package doc names, checked mechanically
// rather than assumed: if replaying a seed does not reproduce the run, a red sweep hands
// back a story instead of a reproducer, and the whole reason to prefer a
// seeded schedule over a random one is gone. It is cheap to check and it
// fails for real reasons -- one `time.Now()` reaching a decision, one
// package-level math/rand, one map iteration whose order escapes into an
// output, and the seed stops determining the run. (internal/architecture's
// TestCoreWallClock_TimeNowBannedExceptAllowlist and
// TestCoreRandomness_MathRandBannedExceptAllowlist, both with EMPTY
// allowlists, are the fitness functions standing behind the first two for
// internal/domain and internal/app; this test is what would notice anything
// they do not cover, including nondeterminism introduced by this harness
// itself.)
func TestSimulation_SeedReproduces(t *testing.T) {
	seed := resolveSeed(t)
	first := runSchedule(t, seed)
	second := runSchedule(t, seed)

	if len(first.trace) != len(second.trace) {
		t.Fatalf("seed=%d: the two runs executed %d and %d steps -- the seed does not determine the schedule", seed, len(first.trace), len(second.trace))
	}
	for i := range first.trace {
		if first.trace[i] != second.trace[i] {
			t.Fatalf("seed=%d: the two runs diverge at trace line %d:\n  run 1: %s\n  run 2: %s", seed, i, first.trace[i], second.trace[i])
		}
	}
	t.Logf("seed=%d reproduces: %d trace lines identical across two runs", seed, len(first.trace))
}

// runSchedule derives the schedule from seed and executes it, asserting the
// invariants after every step. It is shared by the two tests above so the
// reproducibility check compares the SAME machine, not a simplified copy of
// it -- a determinism check against a reduced harness proves the reduction is
// deterministic and nothing else.
func runSchedule(t *testing.T, seed int64) *simulation {
	t.Helper()
	t.Cleanup(func() {
		if t.Failed() {
			t.Logf("SIMULATION FAILED -- reproduce this exact schedule with: SIM_SEED=%d make sim", seed)
		}
	})

	// rand.New(rand.NewSource(seed)), not the package-level functions: only a
	// LOCAL generator is reproducible. math/rand's own Seed doc says it --
	// "Programs that call Seed with a known value to get a specific sequence
	// of results should use New(NewSource(seed)) to obtain a local random
	// generator" -- and as of Go 1.24 the package-level Seed is a no-op, so a
	// harness built on it would silently draw a fresh schedule every run.
	// math/rand/v2 has no Seed at all and its top-level source is always
	// randomly seeded, which is why this file stays on v1, like
	// internal/domain/ledger_property_test.go.
	rng := rand.New(rand.NewSource(seed))
	s := newSimulation(t, seed, newSchedule(rng, scheduleLength))

	for s.index = 0; s.index < len(s.steps); s.index++ {
		st := s.steps[s.index]
		s.clockAt = simEpoch.Add(time.Duration(s.index) * time.Second)

		switch st.kind {
		case opDeposit:
			s.command(st, domain.EventDeposited)
		case opWithdraw:
			s.command(st, domain.EventWithdrawn)
		case opDuplicateDelivery:
			s.duplicateDelivery(st)
		case opAppendFailure:
			s.appendFailure(st)
		case opRestart:
			s.restart()
		default:
			t.Fatalf("%s: unscheduled op kind %d", s.where(), st.kind)
		}

		s.assertInvariants()

		// One trace line per step, recording the whole observable world and
		// not only the balance: a trace that carried less would compare equal
		// across two runs that had diverged somewhere it does not look.
		state := s.ledger.State()
		s.trace = append(s.trace, fmt.Sprintf("%03d %-18s balance=%s version=%d durable=%d log=%08x nudges=%d applied=%d minted=%d",
			s.index, st.kind, state.Balance, state.Version, len(s.journal.events), s.journal.digest.Sum32(), s.nudges, len(state.Applied), s.minted))
		s.balances[state.Balance] = true
	}
	return s
}

// resolveSeed reads SIM_SEED, or returns defaultSeed when it is unset.
//
// A malformed SIM_SEED is FATAL rather than a fallback to the default on
// purpose: a typo'd seed that silently runs the default reports a green run
// for a schedule nobody asked for -- and the person who asked for it is
// usually someone reproducing a failure, i.e. exactly the reader who would
// conclude the bug is gone.
func resolveSeed(t *testing.T) int64 {
	t.Helper()
	raw, ok := os.LookupEnv("SIM_SEED")
	if !ok || raw == "" {
		return defaultSeed
	}
	seed, err := strconv.ParseInt(raw, 10, 64)
	if err != nil {
		t.Fatalf("SIM_SEED=%q is not a base-10 int64: %v", raw, err)
	}
	return seed
}

// command runs one deposit or withdrawal through the ledger's real command
// path and folds the outcome into the harness's independent tracker.
func (s *simulation) command(st step, eventType domain.EventType) {
	s.t.Helper()

	// A deliberate overdraft is sized from the balance the ledger holds RIGHT
	// NOW -- s.expected, the harness's own tracker, which assertInvariants
	// proved equal to the ledger's balance at the end of the previous step.
	// Sizing it from a constant instead would make the attempt a coin flip
	// once the balance grew past it.
	amountUnits := big.NewInt(st.units)
	if st.overdraft {
		amountUnits = new(big.Int).Add(s.expected, big.NewInt(1+st.units%1_000))
	}
	amount := domain.FormatAmount(amountUnits)

	id := ""
	if !st.mint {
		id = s.freshID()
	}

	var (
		out app.CommandOutcome
		err error
	)
	if eventType == domain.EventDeposited {
		out, err = s.ledger.Deposit(context.Background(), id, amount)
	} else {
		out, err = s.ledger.Withdraw(context.Background(), id, amount)
	}
	if err != nil {
		s.t.Fatalf("%s: command returned an unexpected error: %v", s.where(), err)
	}

	// An overdraft attempt that is ADMITTED is the defect this domain exists
	// to prevent (a balance driven negative), so it is checked before the
	// effect switch rather than left to the conservation comparison, which
	// would report it as an arithmetic mismatch and bury the cause.
	if st.overdraft {
		if _, ok := out.Effects[0].(domain.EffectWithdrawalRejected); !ok {
			s.t.Fatalf("%s: withdrawal of %s against a balance of %s produced effects[0] = %#v, want EffectWithdrawalRejected", s.where(), amount, domain.FormatAmount(s.expected), out.Effects[0])
		}
	}

	var gotID string
	switch effect := out.Effects[0].(type) {
	case domain.EffectDeposited:
		gotID = effect.EventID
		s.expected.Add(s.expected, amountUnits)
		s.admitted = append(s.admitted, domain.Event{ID: effect.EventID, Type: domain.EventDeposited, Amount: amount})
		s.deposits++
	case domain.EffectWithdrawn:
		gotID = effect.EventID
		s.expected.Sub(s.expected, amountUnits)
		s.admitted = append(s.admitted, domain.Event{ID: effect.EventID, Type: domain.EventWithdrawn, Amount: amount})
		s.withdrawals++
	case domain.EffectWithdrawalRejected:
		// Rejected: the tracker is deliberately NOT updated, which is what
		// makes the next assertInvariants a real check on the ledger having
		// left its balance alone.
		gotID = effect.EventID
		s.rejections++
	default:
		// A well-formed amount under a fresh id can produce nothing else.
		// EffectDuplicateIgnored here would mean the id generator collided;
		// EffectMalformedAmount would mean FormatAmount emitted something
		// ValidateAmount rejects; EffectUnknownEventType would mean this
		// harness invented a type the domain does not declare.
		s.t.Fatalf("%s: effects[0] = %#v, want a deposited/withdrawn/rejected effect", s.where(), effect)
	}

	// A step that supplied no event id must come back carrying one the
	// INJECTED generator produced. Without this the id port could be
	// unwired -- or replaced by a clock read, which is the shape
	// internal/app.IDGenerator exists to forbid -- and every assertion above
	// would still pass.
	if st.mint && !strings.HasPrefix(gotID, mintedIDPrefix) {
		s.t.Fatalf("%s: command with an empty event id came back with %q, want an id minted by the injected generator (%q prefix)", s.where(), gotID, mintedIDPrefix)
	}
	if !st.mint && gotID != id {
		s.t.Fatalf("%s: command supplied event id %q but the effect names %q", s.where(), id, gotID)
	}
}

// duplicateDelivery redelivers an already-admitted event, byte-identical,
// through the same public command path a redelivering client would use --
// the at-least-once delivery fault. The ledger must absorb it: no balance
// change, no version change, nothing appended, and the domain's own
// EffectDuplicateIgnored as the answer.
//
// When nothing has been admitted yet there is nothing to duplicate; the step
// degrades into a deposit rather than being skipped, so a schedule whose
// early duplicates land on an empty ledger still does work, and the
// duplicate counter still tells the truth about how many real duplicates
// were exercised.
func (s *simulation) duplicateDelivery(st step) {
	s.t.Helper()
	if len(s.admitted) == 0 {
		s.command(step{kind: opDeposit, units: 1_000}, domain.EventDeposited)
		return
	}

	pick := int(st.pick * float64(len(s.admitted)))
	if pick >= len(s.admitted) {
		pick = len(s.admitted) - 1
	}
	original := s.admitted[pick]

	before := s.ledger.State()
	durableBefore := len(s.journal.events)

	var (
		out app.CommandOutcome
		err error
	)
	if original.Type == domain.EventDeposited {
		out, err = s.ledger.Deposit(context.Background(), original.ID, original.Amount)
	} else {
		out, err = s.ledger.Withdraw(context.Background(), original.ID, original.Amount)
	}
	if err != nil {
		s.t.Fatalf("%s: redelivery of %q returned an error: %v", s.where(), original.ID, err)
	}

	if _, ok := out.Effects[0].(domain.EffectDuplicateIgnored); !ok {
		s.t.Fatalf("%s: redelivery of %q produced effects[0] = %#v, want EffectDuplicateIgnored", s.where(), original.ID, out.Effects[0])
	}
	after := s.ledger.State()
	if after.Balance != before.Balance {
		s.t.Fatalf("%s: redelivery of %q changed the balance %q -> %q (duplicate_event_single_effect)", s.where(), original.ID, before.Balance, after.Balance)
	}
	if after.Version != before.Version {
		s.t.Fatalf("%s: redelivery of %q advanced the version %d -> %d (duplicate_event_single_effect)", s.where(), original.ID, before.Version, after.Version)
	}
	if got := len(s.journal.events); got != durableBefore {
		s.t.Fatalf("%s: redelivery of %q appended to the durable log (%d -> %d records); the log's contract is that everything in it happened", s.where(), original.ID, durableBefore, got)
	}
	s.duplicates++
}

// appendFailure injects a durable-append failure underneath a command, then
// RETRIES the same event id.
//
// Both halves are the point. The first proves the app layer's csApplied ->
// csLogged transition: the decision dies with the append, so committed state
// never runs ahead of the durable log. The second proves the failure left no
// poison behind -- domain.Apply marks an id Applied only when it admits the
// event, so a command whose append failed must still be admissible under the
// SAME id. A fault whose recovery is never exercised only shows the system
// can fail, not that it stays usable.
func (s *simulation) appendFailure(st step) {
	s.t.Helper()
	amount := domain.FormatAmount(big.NewInt(st.units))
	id := s.freshID()

	before := s.ledger.State()
	durableBefore := len(s.journal.events)
	nudgesBefore := s.nudges

	s.journal.failNext = true
	out, err := s.ledger.Deposit(context.Background(), id, amount)
	if err == nil {
		s.t.Fatalf("%s: deposit %q succeeded although its durable append was injected to fail", s.where(), id)
	}
	if !errors.Is(err, errInjectedAppend) {
		s.t.Fatalf("%s: deposit %q failed with %v, want the injected append failure wrapped", s.where(), id, err)
	}
	// "applied": decided in memory, never made durable (internal/app's
	// commandState.String()). A "committed" stage here would mean the ledger
	// reported success for a fact no log supports.
	if out.Stage != "applied" {
		s.t.Fatalf("%s: deposit %q reported stage %q, want \"applied\" (decided, never made durable)", s.where(), id, out.Stage)
	}
	after := s.ledger.State()
	if after.Balance != before.Balance || after.Version != before.Version {
		s.t.Fatalf("%s: state advanced past a failed append: %+v -> %+v", s.where(), before, after)
	}
	if got := len(s.journal.events); got != durableBefore {
		s.t.Fatalf("%s: the durable log grew (%d -> %d) although the append failed", s.where(), durableBefore, got)
	}
	if s.nudges != nudgesBefore {
		s.t.Fatalf("%s: the relay was nudged (%d -> %d) for an event that was never appended", s.where(), nudgesBefore, s.nudges)
	}
	s.faults++

	// --- recovery: the SAME id must still be admissible -------------------
	retried, err := s.ledger.Deposit(context.Background(), id, amount)
	if err != nil {
		s.t.Fatalf("%s: retry of %q after a failed append returned an error: %v", s.where(), id, err)
	}
	if _, ok := retried.Effects[0].(domain.EffectDeposited); !ok {
		s.t.Fatalf("%s: retry of %q produced effects[0] = %#v, want EffectDeposited -- the failed append poisoned the id", s.where(), id, retried.Effects[0])
	}
	s.expected.Add(s.expected, big.NewInt(st.units))
	s.admitted = append(s.admitted, domain.Event{ID: id, Type: domain.EventDeposited, Amount: amount})
	s.deposits++
}

// restart rebuilds the state from the surviving journal and continues on a
// fresh Ledger over the same log -- what the composition root does at boot,
// with the process boundary elided (see the package doc: eliding it is
// exactly the stage-1 limitation).
func (s *simulation) restart() {
	s.t.Helper()
	s.assertReplayMatchesMemory("restart")

	replayed := eventlog.Rebuild(s.journal.events)
	s.ledger = app.NewLedger(replayed, s.journal, func() { s.nudges++ }, s.clockFn, s.idsFn)
	s.restarts++
}

// assertReplayMatchesMemory folds the whole durable log from genesis and
// requires it to reproduce what the process holds in memory -- balance,
// version and the applied-id set alike.
//
// This is the property that makes a restart safe, and it is checked at every
// restart plus once at the end rather than after every step: the fold is
// O(events) with a map clone per admission, so per-step it would dominate
// the run, and the only way memory and log can diverge is an admission that
// decides differently on replay -- which is what a restart step exercises.
func (s *simulation) assertReplayMatchesMemory(when string) {
	s.t.Helper()
	memory := s.ledger.State()
	replayed := eventlog.Rebuild(s.journal.events)

	if replayed.Balance != memory.Balance {
		s.t.Fatalf("%s: %s replay balance = %q, in-memory balance = %q (the log does not reproduce the running state)", s.where(), when, replayed.Balance, memory.Balance)
	}
	if replayed.Version != memory.Version {
		s.t.Fatalf("%s: %s replay version = %d, in-memory version = %d", s.where(), when, replayed.Version, memory.Version)
	}
	replayedIDs, memoryIDs := replayed.AppliedIDs(), memory.AppliedIDs()
	if len(replayedIDs) != len(memoryIDs) {
		s.t.Fatalf("%s: %s replay applied %d ids, memory holds %d", s.where(), when, len(replayedIDs), len(memoryIDs))
	}
	for i := range replayedIDs {
		if replayedIDs[i] != memoryIDs[i] {
			s.t.Fatalf("%s: %s replay applied-id set diverges at %d: %q vs %q", s.where(), when, i, replayedIDs[i], memoryIDs[i])
		}
	}
}

// assertInvariants runs after EVERY step. Each check compares two
// independent computations; none of them asks the ledger to confirm itself.
func (s *simulation) assertInvariants() {
	s.t.Helper()
	state := s.ledger.State()

	// units_conserved (ratified): the harness's own big.Int sum of admitted
	// deposits minus admitted withdrawals must equal the ledger's balance.
	if want := domain.FormatAmount(s.expected); state.Balance != want {
		s.t.Fatalf("%s: balance = %q, want %q (independently tracked: admitted deposits minus admitted withdrawals)", s.where(), state.Balance, want)
	}

	// The version is the domain's own admission signal, and every admission
	// is appended before the state advances -- so a version that outruns the
	// log is committed state with no durable record behind it, and a log that
	// outruns the version is a fact the process forgot.
	if int(state.Version) != len(s.journal.events) {
		s.t.Fatalf("%s: version = %d but the durable log holds %d records", s.where(), state.Version, len(s.journal.events))
	}

	// One nudge per durable event, never one for an event that was not
	// appended (see the append-failure step, which checks the same thing at
	// the moment of the fault).
	if s.nudges != len(s.journal.events) {
		s.t.Fatalf("%s: relay nudges = %d, durable records = %d", s.where(), s.nudges, len(s.journal.events))
	}

	// The RUNTIME mirrors of the same two ratified invariants
	// (internal/app/invariants.go), which is what production would page on.
	// A restart builds a fresh Ledger with fresh counters, so this reads the
	// current ledger's lifetime -- adequate because it is checked after every
	// step, so a violation is seen before the next restart can clear it.
	if v := s.ledger.ConservationViolations(); v != 0 {
		s.t.Fatalf("%s: the ledger's own conservation-violation counter is %d, want 0", s.where(), v)
	}
	if v := s.ledger.DuplicateEffectViolations(); v != 0 {
		s.t.Fatalf("%s: the ledger's own duplicate-effect-violation counter is %d, want 0", s.where(), v)
	}
}

// assertScheduleAdequacy is this harness's answer to its own vacuous form.
//
// Every floor below is a FLOOR, not a target. Measured on the default seed
// (2026-08-27): deposits 239, admitted withdrawals 129, rejections 43,
// duplicate deliveries 68, injected append faults 37, restarts 21, minted
// ids 46, distinct balances 369 -- and across the seven seeds swept that day
// (20260827, 1, 7, 42, 999983, -12345, 123456789) the smallest value any
// counter took was: deposits 237, withdrawals 120, rejections 42,
// duplicates 51, faults 33, restarts 21, minted 43, balances 363. The floors
// sit under those minima with room, so a sweep does not turn adequacy into a
// flake -- while still failing loudly if the schedule ever collapses toward
// one kind of operation. A simulation that only deposits still passes
// conservation, and proves nothing.
//
// These are t.Errorf, not t.Fatalf: an inadequate schedule is a defect in
// this harness, and a reader deserves to see EVERY counter that fell short
// in one run rather than the first one alphabetically.
func assertScheduleAdequacy(s *simulation) {
	s.t.Helper()

	if s.index != len(s.steps) {
		s.t.Fatalf("seed=%d: executed %d of %d scheduled steps", s.seed, s.index, len(s.steps))
	}

	// Logged unconditionally so `go test -v ./verification/simulation/`
	// REPRODUCES the numbers quoted in this function's doc comment instead of
	// asking a reader to trust them, and so a failing run shows what the
	// schedule actually did next to the assertion that rejected it.
	s.t.Logf("schedule adequacy (seed=%d, %d steps): deposits=%d withdrawals=%d rejections=%d duplicates=%d append_faults=%d restarts=%d minted_ids=%d distinct_balances=%d",
		s.seed, len(s.steps), s.deposits, s.withdrawals, s.rejections, s.duplicates, s.faults, s.restarts, s.minted, len(s.balances))

	for _, c := range []struct {
		name  string
		got   int
		floor int
		why   string
	}{
		{"admitted deposits", s.deposits, 150, "the workload never credited the ledger"},
		{"admitted withdrawals", s.withdrawals, 60, "no withdrawal was ever affordable, so the debit path never ran"},
		{"rejected withdrawals", s.rejections, 20, "the insufficient-balance branch was never exercised"},
		{"duplicate deliveries", s.duplicates, 25, "the idempotency guard was never exercised against a real redelivery"},
		{"injected append failures", s.faults, 15, "the durable-append failure path never ran"},
		{"state-replay restarts", s.restarts, 8, "state was never rebuilt from the log"},
		{"ids minted by the injected generator", s.minted, 20, "the injected IDGenerator port was never exercised"},
	} {
		if c.got < c.floor {
			s.t.Errorf("schedule adequacy: %s = %d, want >= %d -- %s (seed=%d)", c.name, c.got, c.floor, c.why, s.seed)
		}
	}

	// State diversity: a schedule that oscillates between two balances would
	// satisfy every count above while exercising a sliver of the state space.
	const minDistinctBalances = 250
	if len(s.balances) < minDistinctBalances {
		s.t.Errorf("schedule adequacy: only %d distinct balances observed across %d steps, want >= %d (seed=%d)", len(s.balances), len(s.steps), minDistinctBalances, s.seed)
	}
}
