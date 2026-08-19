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
	"time"
)

func main() {
	if err := run(); err != nil {
		slog.Error("svc: fatal", "error", err)
		os.Exit(1)
	}
}

func run() error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	logger := slog.Default()

	build := buildinfo.Get()
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
	logger.Info("svc: recovered state",
		"from_snapshot", recovered.SnapshotFound,
		"events_replayed", recovered.EventsReplayed,
		"records_scanned", recovered.RecordsScanned,
		"balance", initial.Balance)
	if recovered.SnapshotsRejected > 0 {
		// A rejected snapshot is not fatal -- recovery fell back and the
		// state is correct -- but it means boot just paid full-replay cost
		// for a reason nobody asked about. Say so at ERROR so it cannot be
		// mistaken for a normal start.
		logger.Error("svc: snapshot rejected, recovered by full replay instead",
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
	rebuilt, err := rebuildOutboxFromLog(cfg.EventLogPath, outbox)
	if err != nil {
		return err
	}
	if rebuilt > 0 {
		logger.Warn("svc: recovered effects the outbox never journaled",
			"effects", rebuilt,
			"cause", "crash between the state commit and the effect journal")
	}

	// -- orchestration core --------------------------------------------------
	ledger := app.NewLedger(initial, log, outbox, clock.Real{}.Now, ids.Real{}.NewID)
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

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	var wg sync.WaitGroup

	healthLis, err := net.Listen("tcp", portAddr(cfg.HealthPort))
	if err != nil {
		return err
	}
	wg.Add(1)
	go func() {
		defer wg.Done()
		if err := healthSrv.ServeListener(ctx, healthLis); err != nil {
			logger.Error("svc: health server", "error", err)
		}
	}()
	logger.Info("svc: serving health", "addr", healthLis.Addr().String())

	if cfg.PprofPort != 0 {
		pprofLis, err := net.Listen("tcp", portAddr(cfg.PprofPort))
		if err != nil {
			return err
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := pprofhttp.ServeListener(ctx, pprofLis); err != nil {
				logger.Error("svc: pprof server", "error", err)
			}
		}()
		logger.Info("svc: serving pprof", "addr", pprofLis.Addr().String())
	}

	// -- snapshot + compaction: what keeps boot and storage bounded --------
	wg.Add(1)
	go func() {
		defer wg.Done()
		snapshotLoop(ctx, log, ledger.State, logger, 30*time.Second, eventlog.DefaultSnapshotEvery)
	}()

	<-ctx.Done()
	logger.Info("svc: shutting down")
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
				logger.Error("svc: snapshot failed; log keeps growing", "error", err)
				continue
			}
			stats, err := log.Compact()
			if err != nil {
				// The snapshot IS durable at this point, so the next boot is
				// already bounded. Only the disk reclaim failed.
				logger.Error("svc: compaction failed; snapshot is durable, disk not reclaimed", "error", err)
				continue
			}
			logger.Info("svc: snapshot + compaction",
				"records_before", stats.RecordsBefore, "records_after", stats.RecordsAfter)
		}
	}
}

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
func rebuildOutboxFromLog(eventLogPath string, outbox *store.Outbox) (int, error) {
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
func adaptTracer(tr observability.Tracer) app.SpanFunc {
	return func(name string, attrs map[string]string) func(error) {
		_, span := tr.StartSpan(context.Background(), name, attrs)
		return func(err error) {
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
