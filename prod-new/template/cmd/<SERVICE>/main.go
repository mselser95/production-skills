// Command svc is the composition root -- and ONLY the composition root.
// Every port internal/app and internal/adapter declare gets its real
// implementation wired together here; no business logic lives in this
// package.
package main

import (
	"context"
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
	"github.com/<OWNER>/<SERVICE>/internal/platform/buildinfo"
	"github.com/<OWNER>/<SERVICE>/internal/platform/clock"
	"github.com/<OWNER>/<SERVICE>/internal/platform/config"
	"github.com/<OWNER>/<SERVICE>/internal/platform/eventlog"
	"github.com/<OWNER>/<SERVICE>/internal/platform/ids"
	"github.com/<OWNER>/<SERVICE>/internal/platform/observability"
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

	pastEvents, err := eventlog.Replay(cfg.EventLogPath)
	if err != nil {
		return err
	}
	initial := eventlog.Rebuild(pastEvents)
	logger.Info("svc: replayed event log", "events", len(pastEvents), "balance", initial.Balance)

	// -- outbox (external_effect adapter) ----------------------------------
	outbox := store.NewOutbox(store.NewLogSink(logger), ids.Real{}.NewID, cfg.OutboxMaxAttempts)

	// -- orchestration core --------------------------------------------------
	ledger := app.NewLedger(initial, log, outbox, clock.Real{}.Now, ids.Real{}.NewID)
	ledger.SetTracer(adaptTracer(tracer))

	// -- health/readiness/metrics -------------------------------------------
	healthSrv := healthhttp.New(ledger, healthhttp.Options{
		Log:               log,
		PodID:             cfg.PodID,
		ConfigIdentity:    cfg.Identity(),
		ViolationCooldown: cfg.InvariantViolationCooldown,
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

	<-ctx.Done()
	logger.Info("svc: shutting down")
	wg.Wait()
	return nil
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
