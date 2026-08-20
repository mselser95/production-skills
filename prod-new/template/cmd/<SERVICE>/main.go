// Command svc is the composition root -- and ONLY the composition root.
// Every port internal/app and internal/adapter declare gets its real
// implementation wired together here; no business logic lives in this
// package.
package main

import (
	"context"
	"fmt"
	"log/slog"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"sync"
	"syscall"

	"github.com/<OWNER>/<SERVICE>/internal/adapter/in/healthhttp"
	"github.com/<OWNER>/<SERVICE>/internal/adapter/in/pprofhttp"
	"github.com/<OWNER>/<SERVICE>/internal/adapter/out/store"
	"github.com/<OWNER>/<SERVICE>/internal/app"
	"github.com/<OWNER>/<SERVICE>/internal/domain"
	"github.com/<OWNER>/<SERVICE>/internal/platform/buildinfo"
	"github.com/<OWNER>/<SERVICE>/internal/platform/clock"
	"github.com/<OWNER>/<SERVICE>/internal/platform/config"
	"github.com/<OWNER>/<SERVICE>/internal/platform/eventlog"
	"github.com/<OWNER>/<SERVICE>/internal/platform/ids"
	"github.com/<OWNER>/<SERVICE>/internal/platform/observability"
	"github.com/<OWNER>/<SERVICE>/internal/platform/relay"
	"time"
)

// serviceName identifies this process in the exported OTel resource and is
// the instrumentation scope name on every bridged log record. A constant,
// not config: a pod that can rename the service it claims to be makes every
// downstream query a guess.
const serviceName = "<SERVICE>"

func main() {
	// The signal context is created HERE, not two thirds of the way through
	// run() where it used to live. Two consequences, in order of how much
	// they matter.
	//
	// It gives main() a context, which is what lets the fatal line below be
	// an *Context call rather than the one log line in the process that
	// silently drops its trace context.
	//
	// And it moves the whole boot -- config, event-log recovery, outbox
	// rebuild -- inside the handled window. Before, a SIGTERM arriving
	// during a long replay hit Go's DEFAULT disposition and killed the
	// process outright; nothing was corrupted (every write is journaled
	// first) but nothing was said either, so a pod that died mid-replay was
	// indistinguishable from one that crashed. Now it is a context
	// cancellation the boot path can observe and describe.
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	if err := run(ctx); err != nil {
		// A LOCAL bootstrap logger, not slog's package-level Error.
		//
		// Two reasons, both learned the hard way. slog.Error goes to the
		// default TEXT handler on stderr, so the one line that says why the
		// process refused to start is the one line no log store can parse
		// into fields. And run() may have failed BEFORE it built the
		// configured logger -- config.Load returning an error is the
		// commonest way to reach here -- so there is nothing else to use.
		boot := observability.NewBootstrapLogger(os.Stderr)
		boot.ErrorContext(ctx, "svc: fatal", "error", err)
		cancel()
		os.Exit(1)
	}
}

func run(ctx context.Context) error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}

	build := buildinfo.Get()

	logger, shutdownLogs, err := observability.NewLogger(ctx, os.Stdout, observability.LogOptions{
		Level:          cfg.LogLevel,
		Export:         cfg.LogExport,
		ServiceName:    serviceName,
		ServiceVersion: build.Revision,
	})
	if err != nil {
		return err
	}
	defer func() {
		// context.WithoutCancel is load-bearing on the NORMAL exit path.
		// run() returns from here after <-ctx.Done(), so ctx is already
		// cancelled -- that is why we are shutting down -- and the SDK's
		// Processor contract requires Shutdown and ForceFlush to honor the
		// passed context's cancellation. Handing them the cancelled one
		// would therefore abandon whatever is still in the batch: the last
		// records before exit, which is to say the ones describing the
		// shutdown. A fresh 5s budget is the difference between "the log
		// ends mid-sentence" and "the log says goodbye".
		flushCtx, cancelFlush := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
		defer cancelFlush()
		_ = shutdownLogs(flushCtx)
	}()

	tracer := observability.WithBaseAttrs(
		observability.New(cfg.Tracing, logger),
		map[string]string{"revision": build.Revision, "config_digest": cfg.Digest()},
	)

	// -- durable event journal + boot-time replay -------------------------
	if dir := filepath.Dir(cfg.EventLogPath); dir != "." {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return err
		}
	}
	log, err := eventlog.Open(cfg.EventLogPath)
	if err != nil {
		return err
	}
	defer func() { _ = log.Close() }()

	// Recover, not Replay+Rebuild: recovery starts from the newest snapshot
	// and folds only the events after it, so boot cost tracks
	// history-since-snapshot rather than history-since-genesis.
	initial, recovered, err := eventlog.Recover(cfg.EventLogPath)
	if err != nil {
		return err
	}
	logger.InfoContext(ctx, "svc: recovered state",
		"from_snapshot", recovered.SnapshotFound,
		"events_replayed", recovered.EventsReplayed,
		"records_scanned", recovered.RecordsScanned,
		"balance", initial.Balance)
	if recovered.SnapshotsRejected > 0 {
		// A rejected snapshot is not fatal -- recovery fell back and the
		// state is correct -- but it means boot just paid full-replay cost
		// for a reason nobody asked about. Say so at ERROR so it cannot be
		// mistaken for a normal start.
		logger.ErrorContext(ctx, "svc: snapshot rejected, recovered by full replay instead",
			"rejected", recovered.SnapshotsRejected,
			"events_replayed", recovered.EventsReplayed)
	}

	// -- outbox (external_effect adapter) ----------------------------------
	// OpenDurable, not NewOutbox. The durable form is the whole point of the
	// pattern: journaling an intent before performing the effect only helps
	// if the journal outlives the process. Shipping the in-memory constructor
	// here would have been a durable mechanism nobody ran -- the same defect
	// as a tracer that is instrumented and never injected.
	if dir := filepath.Dir(cfg.OutboxLogPath); dir != "." {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return err
		}
	}
	outbox, err := store.OpenDurable(
		cfg.OutboxLogPath, store.NewLogSink(logger), ids.Real{}.NewID, cfg.OutboxMaxAttempts)
	if err != nil {
		return err
	}
	defer func() { _ = outbox.Close() }()

	// The wake-up half of the outbox's recovery. Created BEFORE anything can
	// journal, so no signal can be raised against a channel that does not
	// exist yet.
	wake, notifyPending := newPendingWake()

	// Close the window between the state commit and the effect journal.
	//
	// process() appends the event, commits the state, unlocks, and only THEN
	// journals the effects -- two durable writes with no transaction between
	// them. A crash in that window used to lose the effect permanently,
	// because the event replays and RebuildFrom discards effects.
	//
	// domain.Apply is pure, so the effects are DERIVABLE. Re-derive them from
	// the log and journal whatever the outbox does not already know about.
	// The outbox is thus a projection of the event log plus a delivery
	// watermark, and the hot path keeps exactly one durable write.
	//
	// The recorder wraps the outbox purely to remember WHICH identities this
	// walk can re-derive. That set is what the outbox log's compaction below
	// is allowed to forget: see rederivableSet's doc for why compacting
	// without it republishes history.
	rederivable := newRederivable(outbox)
	rebuilt, err := rebuildOutboxFromLog(cfg.EventLogPath, rederivable)
	if err != nil {
		return err
	}
	if rebuilt > 0 {
		logger.WarnContext(ctx, "svc: recovered effects the outbox never journaled",
			"effects", rebuilt,
			"cause", "crash between the state commit and the effect journal")
	}

	// -- compact the outbox log --------------------------------------------
	//
	// The outbox log was append-only with no compaction, so it grew with the
	// service's total lifetime effect volume rather than with its live set,
	// and OpenDurable's replay above grew with it. Compacting HERE, at the
	// end of boot, is the one point where both halves of the decision are
	// known: the log has already been replayed into the working set, and the
	// event-log walk has just reported every identity it can still re-derive.
	compactOutboxLog(ctx, outbox, rederivable, logger)

	// Drain NOW, not one tick from now.
	//
	// Unconditional, and deliberately not `if rebuilt > 0`. The outbox can
	// boot holding pending work from either of two independent sources: the
	// reconstruction just above, and its OWN journal replayed by OpenDurable
	// -- an intent a previous process journaled and died before delivering.
	// The second one leaves rebuilt at zero, so gating the signal on it would
	// make exactly the crash the outbox exists for wait out a full interval.
	notifyPending()

	// -- the relay: THE EVENT LOG IS THE OUTBOX ------------------------------
	// Publication is a READ of the log, not a second write beside it. The
	// relay tails the log from a durable checkpoint, maps each event to the
	// integration events consumers receive, publishes them synchronously, and
	// only then advances the checkpoint. A crash between publish and
	// checkpoint redelivers; it cannot lose.
	//
	// This is why the write path has no publisher: there is nothing for a
	// command to deliver, so there is no window between committing a fact and
	// recording the intent to announce it.
	checkpoints, err := relay.OpenCheckpoints(cfg.CheckpointPath)
	if err != nil {
		return err
	}
	publisher := store.NewLogPublisher(logger)
	rel, err := relay.New[eventlog.SeqEvent](
		log, checkpoints, store.EnvelopeMapper(cfg.PublishTopic), publisher,
		relay.NopLeader(), // single-replica scaffold; a multi-replica deployment supplies a real Leader
		relay.Options{Name: "integration-events"},
	)
	if err != nil {
		return err
	}

	// -- orchestration core --------------------------------------------------
	ledger := app.NewLedger(initial, log, rel.Notify, clock.Real{}.Now, ids.Real{}.NewID)
	ledger.SetTracer(adaptTracer(tracer))

	// -- health/readiness/metrics -------------------------------------------
	healthSrv := healthhttp.New(ledger, healthhttp.Options{
		Log:               log,
		PodID:             cfg.PodID,
		ConfigIdentity:    cfg.Identity(),
		ViolationCooldown: cfg.InvariantViolationCooldown,
		// Without this the outbox series report 0 forever: a dead-lettered
		// effect -- one that will never happen without a human -- would be
		// durable, countable, and invisible to every operator. Instrumented
		// but never injected is the same defect as a tracer nobody constructs.
		Outbox: outbox,
	})

	var wg sync.WaitGroup

	healthLis, err := net.Listen("tcp", portAddr(cfg.HealthPort))
	if err != nil {
		return err
	}
	wg.Add(1)
	go func() {
		defer wg.Done()
		if err := healthSrv.ServeListener(ctx, healthLis); err != nil {
			logger.ErrorContext(ctx, "svc: health server", "error", err)
		}
	}()
	logger.InfoContext(ctx, "svc: serving health", "addr", healthLis.Addr().String())

	if cfg.PprofPort != 0 {
		pprofLis, err := net.Listen("tcp", portAddr(cfg.PprofPort))
		if err != nil {
			return err
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := pprofhttp.ServeListener(ctx, pprofLis); err != nil {
				logger.ErrorContext(ctx, "svc: pprof server", "error", err)
			}
		}()
		logger.InfoContext(ctx, "svc: serving pprof", "addr", pprofLis.Addr().String())
	}

	// -- snapshot + compaction: what keeps boot and storage bounded --------
	wg.Add(1)
	go func() {
		defer wg.Done()
		snapshotLoop(ctx, log, ledger.State, logger, 30*time.Second, eventlog.DefaultSnapshotEvery)
	}()

	// -- outbox drain: what turns a DETECTED delivery failure into a
	// RECOVERED one -------------------------------------------------------
	// Without this goroutine every mechanism below it still passes its own
	// tests and none of them ever runs: Reconcile was implemented, tested by
	// two cases, and called from nowhere. See production.yaml's `driven:`
	// block -- main.reconcileLoop is the symbol that proves this line exists.
	wg.Add(1)
	go func() {
		defer wg.Done()
		reconcileLoop(ctx, outbox, wake, logger, outboxReconcileInterval)
	}()

	// The relay runs for the life of the process. Its failure is loud and
	// non-fatal: a broker outage must not stop the service from committing
	// facts, which is the entire reason delivery left the write path.
	wg.Add(1)
	go func() {
		defer wg.Done()
		if err := rel.Run(ctx); err != nil {
			logger.ErrorContext(ctx, "svc: relay stopped", "error", err)
		}
	}()

	<-ctx.Done()
	logger.InfoContext(ctx, "svc: shutting down")
	wg.Wait()
	return nil
}

// snapshotLoop collapses the replay tail on a fixed cadence: once enough
// events have accumulated it writes a snapshot, then compacts the log so the
// history the snapshot subsumes stops occupying disk.
//
// Without this the service is correct and unboundedly slow to start -- boot
// is O(every event ever recorded) and the log file never shrinks. Those two
// grow together, so the failure arrives as a service that takes longer to
// come back every time it restarts, which is exactly when it is least
// affordable.
//
// Order matters and is the whole risk: the snapshot must be durable BEFORE
// anything is discarded. Compact refuses to run without one for that reason,
// so a failed snapshot degrades to "no reclaim this round" rather than to
// lost history.
// The interval and threshold are parameters rather than constants read
// inside so a test can drive this loop in milliseconds instead of waiting
// half a minute to learn whether it snapshots at all. A loop nothing can
// exercise is a loop nobody knows runs.
func snapshotLoop(
	ctx context.Context,
	log *eventlog.Log,
	state func() domain.State,
	logger *slog.Logger,
	every time.Duration,
	threshold int,
) {
	ticker := time.NewTicker(every)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if log.AppendsSinceSnapshot() < threshold {
				continue
			}
			if err := log.Snapshot(state()); err != nil {
				logger.ErrorContext(ctx, "svc: snapshot failed; log keeps growing", "error", err)
				continue
			}
			stats, err := log.Compact()
			if err != nil {
				// The snapshot IS durable at this point, so the next boot is
				// already bounded. Only the disk reclaim failed.
				logger.ErrorContext(ctx, "svc: compaction failed; snapshot is durable, disk not reclaimed", "error", err)
				continue
			}
			logger.InfoContext(ctx, "svc: snapshot + compaction",
				"records_before", stats.RecordsBefore, "records_after", stats.RecordsAfter)
		}
	}
}

// outboxReconcileInterval is the FLOOR on redelivery attempts, not the normal
// path -- the wake-up signal is. It is nonetheless the half that closes the
// gap this loop exists for: a sink that rejected an entry produces nothing
// that would signal on that entry's behalf, so without a clock nothing would
// ever try it again.
//
// Ten seconds is chosen against auto_recovery.recovery_bound in
// production.yaml (30s): a stalled entry gets at least two attempts inside
// the declared bound, so the bound is met by the retry cadence rather than by
// the first attempt happening to succeed.
const outboxReconcileInterval = 10 * time.Second

// newPendingWake returns the channel reconcileLoop selects on and the
// notifier that signals it.
//
// Buffered to exactly ONE, with the send DROPPED when that buffer is full.
// Dropping is correct rather than lossy: a full buffer means a drain is
// already queued, and that queued drain reconciles every pending entry --
// including whatever this signal was about. What the drop buys is the
// property that actually matters, on the other side of the channel: the
// signaller never blocks, so no path that journals an intent can ever be held
// up behind a reconciler waiting on a dead sink.
func newPendingWake() (<-chan struct{}, func()) {
	ch := make(chan struct{}, 1)
	return ch, func() {
		select {
		case ch <- struct{}{}:
		default:
		}
	}
}

// reconcileLoop is the ONLY place this process re-attempts outbox delivery.
//
// It drains on two triggers, and both are load-bearing. The wake-up is what
// keeps a healthy path prompt -- boot recovery signals it, so an intent left
// behind by a crashed predecessor is delivered in milliseconds instead of
// waiting out a full interval. The ticker is the floor, and it is the half
// that recovers from the sink: an entry the sink REJECTED will never be the
// subject of a new signal, so a wake-only loop would detect the failure and
// never return from it.
//
// On shutdown it returns immediately and does NOT attempt a final drain.
// Pending entries are durable and the next boot resumes them (OpenDurable
// replays the journal), so a farewell drain buys nothing and costs precisely
// the thing you least want: when the SINK is the component that is down, a
// "flush before we go" turns a one-second shutdown into a timeout-length one.
//
// The interval is a parameter rather than a constant read inside, for the
// same reason snapshotLoop's is: a loop no test can drive in milliseconds is
// a loop nobody knows runs.
func reconcileLoop(
	ctx context.Context,
	outbox *store.Outbox,
	wake <-chan struct{},
	logger *slog.Logger,
	every time.Duration,
) {
	ticker := time.NewTicker(every)
	defer ticker.Stop()

	drain := func() {
		result := outbox.Reconcile(ctx)
		if result.Resumed == 0 {
			// Silent when there is nothing to do. A line per tick on a
			// healthy service is a line nobody reads on the one tick that
			// matters.
			return
		}
		logger.InfoContext(ctx, "svc: outbox reconciled",
			"resumed", result.Resumed,
			"delivered", result.Delivered,
			"still_down", result.StillDown)
	}

	for {
		select {
		case <-ctx.Done():
			return
		case <-wake:
			drain()
		case <-ticker.C:
			drain()
		}
	}
}

// compactOutboxLog folds the durable outbox log down to its live set and says
// what that reclaimed.
//
// Extracted from run() rather than left inline for the same reason
// rebuildOutboxFromLog is: a boot step nothing can call is a boot step nothing
// can test. It is also the symbol production.yaml's `driven:` block names for
// this mechanism -- *Outbox reaches an interface (healthhttp.OutboxHealth), so
// the linker retains every one of its methods whether or not anything calls
// them, and naming store.(*Outbox).Compact there would pass a service that had
// deleted this call. A plain function in package main belongs to no interface,
// so removing the call below eliminates the symbol and reds that row.
//
// BEST-EFFORT, deliberately. A reclaim that fails costs disk and a slower next
// boot; refusing to serve over it would turn a housekeeping failure into an
// outage. It is logged at WARN because the cost is real and silent: nothing
// else in this process will ever mention that the log stopped shrinking.
func compactOutboxLog(ctx context.Context, outbox *store.Outbox, watermark *rederivableSet, logger *slog.Logger) {
	stats, err := outbox.Compact(watermark.canRederive)
	if err != nil {
		logger.WarnContext(ctx, "svc: outbox log compaction failed, the log keeps growing", "error", err)
		return
	}
	logger.InfoContext(ctx, "svc: compacted the outbox log",
		"rewritten", stats.Rewritten,
		"entries_before", stats.EntriesBefore,
		"entries_after", stats.EntriesAfter,
		"entries_dropped", stats.EntriesDropped(),
		"records_before", stats.RecordsBefore,
		"records_after", stats.RecordsAfter,
		"bytes_reclaimed", stats.BytesReclaimed(),
		"watermark_retained", watermark.count())
}

// derivedJournaler is the narrow slice of the outbox the boot rebuild needs.
// Declared here so the rebuild can be driven by a recorder (below) or a test
// double rather than only by a real durable outbox.
type derivedJournaler interface {
	KnowsIdentity(identity string) bool
	JournalDerived(identity string, effect domain.Effect) (string, error)
}

// rederivableSet remembers every identity the boot rebuild can derive from the
// event log, so outbox-log compaction knows which terminal entries it must NOT
// forget.
//
// WHY THIS EXISTS, and it is not bookkeeping. The outbox is rebuilt at boot as
// a projection of the event log plus a delivery watermark, and THE OUTBOX LOG
// IS THAT WATERMARK: rebuildOutboxFromLog asks KnowsIdentity(identity), and an
// identity the log does not carry reads as an effect lost in the window
// between the two fsyncs, so it is re-journaled for delivery. That is exactly
// right when the record is genuinely absent -- and exactly wrong if compaction
// is what removed it. A compaction that dropped delivered entries
// unconditionally would make every boot re-journal every still-re-derivable
// effect and deliver it again: a DATA-INTEGRITY REGRESSION dressed as a
// cleanup, and the reason "keep only entries with no terminal record" must not
// be read literally.
//
// So compaction may forget a terminal entry only once NOTHING can re-derive
// its identity. This set is that test, and it is precise rather than
// conservative because it is recorded from the very walk whose answers it has
// to predict -- it holds what THIS boot re-derived, and the event log only
// ever loses re-derivable history (eventlog.Compact drops what a snapshot
// subsumes), so a later boot's set is a subset of this one.
//
// The consequence for growth, stated rather than left to be discovered: the
// outbox log is now bounded by the live set PLUS the event log's replay tail,
// not by lifetime effect volume. The tail is what snapshotLoop bounds, so the
// two boundedness guarantees are deliberately joined -- an event log that
// stops snapshotting stops the outbox log shrinking too, and the symptom is a
// growing file rather than a wrong one.
type rederivableSet struct {
	derivedJournaler
	seen map[string]struct{}
}

func newRederivable(inner derivedJournaler) *rederivableSet {
	return &rederivableSet{derivedJournaler: inner, seen: map[string]struct{}{}}
}

// KnowsIdentity records the identity and delegates. It deliberately notes
// EVERY identity the walk presents, not just the ones that were missing:
// "already on disk" is precisely the case whose record compaction must keep,
// and it is the ONLY branch a healthy service ever takes. Recording only in
// JournalDerived would mean a boot that recovered nothing retained nothing --
// which is to say, it would drop the entire delivered history on the first
// clean restart.
func (r *rederivableSet) KnowsIdentity(identity string) bool {
	r.seen[identity] = struct{}{}
	return r.derivedJournaler.KnowsIdentity(identity)
}

// canRederive reports whether the boot rebuild would re-derive this identity.
func (r *rederivableSet) canRederive(identity string) bool {
	_, ok := r.seen[identity]
	return ok
}

// count is how many identities the walk re-derived -- the size of the set
// compaction is forbidden to forget.
func (r *rederivableSet) count() int { return len(r.seen) }

// rebuildOutboxFromLog re-derives every deliverable effect from the durable
// event log and journals the ones the outbox has no record of, returning how
// many it recovered.
//
// Extracted from run() rather than left inline so it is reachable by a test.
// Inline it would be untestable, which is exactly how a recovery path ships as
// decoration -- present, plausible, and never once exercised.
//
// A journaling failure here ABORTS THE BOOT. An effect that cannot be
// journaled is one this process would never deliver and never mention again,
// and starting anyway would mean serving traffic while silently holding a lost
// effect. Refusing to start is the louder and safer of the two.
func rebuildOutboxFromLog(eventLogPath string, outbox derivedJournaler) (int, error) {
	events, err := eventlog.Replay(eventLogPath)
	if err != nil {
		return 0, err
	}

	var recovered int
	var visitErr error
	eventlog.RebuildFromVisit(domain.NewState(), events, func(event domain.Event, effects []domain.Effect) {
		if visitErr != nil {
			return
		}
		for i, effect := range app.DeliverableEffects(effects) {
			identity := app.EffectIdentity(event.ID, i)
			if outbox.KnowsIdentity(identity) {
				continue
			}
			if _, err := outbox.JournalDerived(identity, effect); err != nil {
				visitErr = fmt.Errorf("rebuild outbox for %s: %w", identity, err)
				return
			}
			recovered++
		}
	})
	return recovered, visitErr
}

// adaptTracer bridges internal/platform/observability.Tracer (this
// package's own, real port) into internal/app.SpanFunc (app's narrow,
// import-free port -- see internal/app/ledger.go's doc for why app cannot
// import internal/platform directly). This is the ONE place in the whole
// module allowed to know about both types at once.
//
// The context is threaded through in BOTH directions, and neither is
// decoration. Inbound, so a span can be a child of whatever the caller was
// already doing rather than a new orphan root. Outbound, so the ledger can
// hand the span-carrying context to everything it calls -- which is the only
// way the durable journal can record this span's traceparent, and the only
// way a log line emitted during the span can carry that span's trace id.
//
// This function used to read
//
//	_, span := tr.StartSpan(context.Background(), name, attrs)
//	return func(err error) { ... }
//
// -- the caller's context dropped on the way IN, the span's context dropped
// on the way OUT. Spans were still emitted, every test passed, and
// correlation was structurally impossible: no context anywhere in the process
// ever contained a span, so nothing could be a parent and nothing could be a
// child. The whole suite was blind to it, because each mechanism was correct
// in isolation. TestAdaptTracer_ThreadsTheSpanContextInBothDirections is the
// guard, and it asserts both halves separately for exactly that reason.
func adaptTracer(tr observability.Tracer) app.SpanFunc {
	return func(ctx context.Context, name string, attrs map[string]string) (context.Context, func(error)) {
		ctx, span := tr.StartSpan(ctx, name, attrs)
		return ctx, func(err error) {
			span.RecordError(err)
			span.End()
		}
	}
}

// portAddr returns the listen address for port, or an ephemeral loopback
// port ("127.0.0.1:0") when port is 0 -- used by tests that want a real
// listener without claiming a fixed port.
func portAddr(port int) string {
	if port == 0 {
		return "127.0.0.1:0"
	}
	return ":" + strconv.Itoa(port)
}
