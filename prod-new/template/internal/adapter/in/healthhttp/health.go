// Package healthhttp serves /healthz, /readyz and /metrics for this
// service's pod.
//
// It deliberately does NOT depend on prometheus/client_golang or any other
// metrics library: /metrics is hand-rolled Prometheus text (fmt.Fprintf) --
// go.mod stays stdlib-only.
//
// Layering: this is a DRIVING (in) adapter. internal/app is permitted to be
// imported here (internal/architecture/boundaries_test.go only forbids
// internal/adapter/in from importing internal/adapter/out), but this
// package deliberately declares its own narrow LedgerHealth/EventLogHealth
// ports instead -- internal/app.Ledger and internal/platform/eventlog.Log
// satisfy them structurally, so this package's tests never need a real
// Ledger or Log to exercise the HTTP surface. It imports
// internal/platform/{buildinfo,config} for operational-determinism fields,
// and never imports internal/adapter/out.
package healthhttp

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"sort"
	"sync/atomic"
	"time"

	"github.com/<OWNER>/<SERVICE>/internal/platform/buildinfo"
	"github.com/<OWNER>/<SERVICE>/internal/platform/config"
)

// EventLogHealth is the narrow port this package needs from the durable
// event journal, satisfied structurally by
// internal/platform/eventlog.(*Log).Writable without importing
// internal/platform/eventlog (adapter/in is free to import platform, but
// keeping this port primitive-typed and locally declared -- the same
// discipline internal/app's own ports use -- keeps healthhttp decoupled
// from eventlog's concrete type for tests).
type EventLogHealth interface {
	Writable() bool
}

// LedgerHealth is the narrow port this package needs from internal/app.Ledger.
// internal/app.Ledger satisfies this structurally.
type LedgerHealth interface {
	ConservationViolations() int64
	DuplicateEffectViolations() int64
	LastInvariantViolationAt() time.Time
}

// OutboxHealth is the narrow port for outbox drain health, satisfied
// structurally by internal/adapter/out/store.(*Outbox).
//
// Declared here rather than importing internal/adapter/out, which
// internal/architecture/boundaries_test.go forbids adapter/in from doing.
//
// DeadLetterCount is the one that matters most. An entry the outbox gave up
// on is an effect that will never happen unless a human intervenes, and
// without a series for it the dead-letter store is a deletion with extra
// steps -- durable, countable, and invisible to everyone outside the process.
type OutboxHealth interface {
	PendingStats() (count int, oldestAge time.Duration, unknownAge int)
	DeadLetterCount() int
}

// Options configures optional collaborators. Every field is optional; a
// Server built with the zero Options still serves /healthz, /readyz (with
// the log-writable gate reporting false, since there is no log) and
// /metrics.
type Options struct {
	Log EventLogHealth
	// Outbox supplies outbox drain health. Nil is legal and reports zeroes.
	Outbox OutboxHealth
	// ViolationCooldown bounds how long a detected invariant violation
	// keeps /readyz failing after the last one observed. Zero means "use
	// DefaultViolationCooldown".
	ViolationCooldown time.Duration
	// PodID is stamped on /healthz's body. Empty is legal.
	PodID string
	// ConfigIdentity is surfaced on /healthz and the build_info metric --
	// see config.Config.Identity.
	ConfigIdentity config.Identity
}

// DefaultViolationCooldown is used when Options.ViolationCooldown is zero.
const DefaultViolationCooldown = 30 * time.Second

// Server serves this pod's health/readiness/metrics endpoints.
type Server struct {
	ledger LedgerHealth
	log    EventLogHealth
	opts   Options
	build  buildinfo.Info

	// Invariant-violation-audit counters -- see invariant_counters.go.
	staleReadyAudits atomic.Int64
}

// New constructs a Server. ledger may be nil (a pod with no live ledger,
// e.g. a health-only smoke test) -- every gate degrades to "not ready"
// rather than panicking.
func New(ledger LedgerHealth, opts Options) *Server {
	if opts.ViolationCooldown <= 0 {
		opts.ViolationCooldown = DefaultViolationCooldown
	}
	return &Server{ledger: ledger, log: opts.Log, opts: opts, build: buildinfo.Get()}
}

// Checks is the readiness gate breakdown returned by ReadinessAt, and
// rendered in /readyz's JSON body.
type Checks struct {
	LogWritable                bool `json:"log_writable"`
	NoRecentInvariantViolation bool `json:"no_recent_invariant_violation"`
}

// ReadinessAt evaluates readiness AS OF `now`, rather than reading the wall
// clock -- the seam that lets a test evaluate "was this pod ready at time
// T" and "is the SAME state stale at T+delta" without fast-forwarding a
// real clock. /readyz's handler calls this with time.Now(); every test
// (including verification/ratified's) calls it directly with a
// caller-supplied `now`.
func (s *Server) ReadinessAt(now time.Time) (bool, Checks) {
	logOK := s.log != nil && s.log.Writable()

	violationOK := true
	if s.ledger != nil {
		last := s.ledger.LastInvariantViolationAt()
		if !last.IsZero() {
			violationOK = now.Sub(last) > s.opts.ViolationCooldown
		}
	}

	ready := logOK && violationOK
	s.auditReadiness(ready, logOK, violationOK)
	return ready, Checks{LogWritable: logOK, NoRecentInvariantViolation: violationOK}
}

// ServeListener serves this Server's handler on an already-bound listener
// until ctx is cancelled, then gracefully shuts down. Tests hand this a
// listener bound with net.Listen("tcp", "127.0.0.1:0") and read its real
// port back off lis.Addr() -- never close-then-rebind, which races another
// parallel test for the same port.
func (s *Server) ServeListener(ctx context.Context, lis net.Listener) error {
	srv := &http.Server{Handler: s.mux()}
	errCh := make(chan error, 1)
	go func() { errCh <- srv.Serve(lis) }()

	select {
	case <-ctx.Done():
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		return srv.Shutdown(shutdownCtx)
	case err := <-errCh:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	}
}

func (s *Server) mux() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", s.handleHealthz)
	mux.HandleFunc("/readyz", s.handleReadyz)
	mux.HandleFunc("/metrics", s.handleMetrics)
	return mux
}

func (s *Server) handleHealthz(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	_, _ = fmt.Fprintf(w, `{"status":"ok","pod_id":%q,"revision":%q,"config_digest":%q}`,
		s.opts.PodID, s.build.Revision, s.opts.ConfigIdentity.Digest)
}

func (s *Server) handleReadyz(w http.ResponseWriter, r *http.Request) {
	ready, checks := s.ReadinessAt(time.Now())
	w.Header().Set("Content-Type", "application/json")
	if !ready {
		w.WriteHeader(http.StatusServiceUnavailable)
	}
	_, _ = fmt.Fprintf(w, `{"ready":%t,"checks":{"log_writable":%t,"no_recent_invariant_violation":%t}}`,
		ready, checks.LogWritable, checks.NoRecentInvariantViolation)
}

func (s *Server) handleMetrics(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; version=0.0.4")

	var conservation, duplicate int64
	if s.ledger != nil {
		conservation = s.ledger.ConservationViolations()
		duplicate = s.ledger.DuplicateEffectViolations()
	}

	writeMetric(w, "svc_build_info", "gauge",
		"Build identity: always 1, the signal lives in the labels.",
		fmt.Sprintf(`{revision=%q,config_digest=%q}`, s.build.Revision, s.opts.ConfigIdentity.Digest), 1)

	writeMetric(w, "svc_units_conserved_violations_total", "counter",
		"Ratified invariant units_conserved: must stay 0. Incremented only when a runtime check detects a real conservation mismatch.",
		"", float64(conservation))

	writeMetric(w, "svc_duplicate_event_violations_total", "counter",
		"Ratified invariant duplicate_event_single_effect: must stay 0.",
		"", float64(duplicate))

	writeMetric(w, "svc_readyz_stale_never_ready_audits_total", "counter",
		"Runtime audit of the readiness gate's own correctness (see invariant_counters.go): must stay 0.",
		"", float64(s.staleReadyAudits.Load()))

	logOK := 0.0
	if s.log != nil && s.log.Writable() {
		logOK = 1
	}
	writeMetric(w, "svc_eventlog_writable", "gauge", "1 if the durable event log is open for writing.", "", logOK)

	// -- outbox drain health ------------------------------------------------
	var pending, unknownAge, deadLettered int
	var oldest time.Duration
	if s.opts.Outbox != nil {
		pending, oldest, unknownAge = s.opts.Outbox.PendingStats()
		deadLettered = s.opts.Outbox.DeadLetterCount()
	}

	writeMetric(w, "svc_outbox_pending_entries", "gauge",
		"Effects journaled but not yet delivered. Rising is NORMAL during a brief sink outage; what matters is whether it DRAINS, so alert on the age below rather than on this count.",
		"", float64(pending))

	writeMetric(w, "svc_outbox_oldest_pending_age_seconds", "gauge",
		"Age of the oldest pending entry. This is the one worth paging on: a lost publish is silent and unrecoverable, unlike a lost submit which fails safe.",
		"", oldest.Seconds())

	writeMetric(w, "svc_outbox_unknown_age_entries", "gauge",
		"Pending entries restored from a schema-1 record that carried no timestamp, so their age is genuinely unknown. Counted separately because \"nothing here is old\" and \"I cannot tell you if anything is old\" support opposite conclusions.",
		"", float64(unknownAge))

	writeMetric(w, "svc_outbox_dead_lettered_total", "gauge",
		"Entries the outbox gave up on after exhausting its bounds. Each is an effect that will NOT happen without a human requeueing it. Must stay 0; non-zero is an incident, not a warning.",
		"", float64(deadLettered))
}

// writeMetric renders one Prometheus text-exposition series (HELP, TYPE,
// and one sample line), sorted output not required since each metric is
// emitted exactly once per scrape (no label cardinality beyond the single
// build_info line, which carries its own fixed label set).
func writeMetric(w http.ResponseWriter, name, typ, help, labels string, value float64) {
	_, _ = fmt.Fprintf(w, "# HELP %s %s\n", name, help)
	_, _ = fmt.Fprintf(w, "# TYPE %s %s\n", name, typ)
	_, _ = fmt.Fprintf(w, "%s%s %v\n", name, labels, value)
}

// MetricNames returns every series this handler can emit, in a stable
// sorted order -- used by the observability contract test to compare
// against observability/emitted-metrics.yaml.
func MetricNames() []string {
	names := []string{
		"svc_build_info",
		"svc_units_conserved_violations_total",
		"svc_duplicate_event_violations_total",
		"svc_readyz_stale_never_ready_audits_total",
		"svc_eventlog_writable",
		"svc_outbox_pending_entries",
		"svc_outbox_oldest_pending_age_seconds",
		"svc_outbox_unknown_age_entries",
		"svc_outbox_dead_lettered_total",
	}
	sort.Strings(names)
	return names
}
