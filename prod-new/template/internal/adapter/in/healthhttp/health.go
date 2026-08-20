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
	"encoding/json"
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

	// CompactionStats reports what boot compaction did to the durable outbox
	// log: how many times it ran, how many entries it folded away, and how
	// many bytes that reclaimed.
	//
	// On the port because the alternative -- counting in-process and never
	// emitting -- leaves the bound implemented but unobserved. A compaction
	// that silently stops reclaiming is indistinguishable from one that has
	// nothing to reclaim, and the two have opposite consequences: the second
	// is a healthy quiet service, the first is a log growing back toward the
	// unbounded shape compaction was added to remove.
	CompactionStats() (runs, entriesDropped int, bytesReclaimed int64)
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
	// OTLPExportFailures reports how many OTLP exports have failed since
	// boot. The composition root passes
	// observability.OTLPExportFailures; nil is legal and reports 0.
	//
	// A FUNCTION, not an interface or an import, so this package keeps
	// knowing nothing about OpenTelemetry -- the same reason internal/app
	// declares its own SpanFunc rather than accepting a Tracer. And it is
	// here at all because a telemetry-export failure is a failure branch,
	// and a failure branch with no series is one an operator can only find
	// by already suspecting it: the WARN it also emits is a poor signal for
	// "your logs may not be reaching you", which is one of the two cases
	// this counts.
	OTLPExportFailures func() int64
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

// handleHealthz reports liveness plus this pod's full config IDENTITY.
//
// THE IDENTITY IS MARSHALLED, not hand-formatted field by field, and that is
// the fix for a defect this endpoint carried silently. It used to print four
// literals -- status, pod_id, revision, config_digest -- while docs/RUNBOOK.md
// told operators to read `tracing`, `log_level` and `log_export` off it.
// config.Identity exists precisely to answer "which config produced this",
// every one of its fields is JSON-tagged for this response, and NONE of them
// reached the wire: only `.Digest` was read. A digest answers "did the config
// change"; it cannot answer "is this pod exporting traces, and to where",
// which is the question the runbook procedure actually asks.
//
// json.Marshal over the struct means the next field added to config.Identity
// is surfaced automatically instead of being forgotten here --
// TestHealthz_SurfacesEveryConfigIdentityField compares the response against
// the struct's own field set, so the drift cannot happen twice.
func (s *Server) handleHealthz(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	body, err := json.Marshal(struct {
		Status string `json:"status"`
		PodID  string `json:"pod_id"`
		// Revision and ConfigDigest stay at the TOP LEVEL, duplicating
		// `config.digest` below, because they are the pre-existing contract
		// (and the two labels on the svc_build_info series). A field that
		// dashboards and probes already read does not get moved to make a
		// new one fit.
		Revision     string `json:"revision"`
		ConfigDigest string `json:"config_digest"`
		// Config is the whole identity, NESTED rather than flattened so a
		// field added to config.Identity can never collide with one of the
		// three above.
		Config config.Identity `json:"config"`
	}{
		Status:       "ok",
		PodID:        s.opts.PodID,
		Revision:     s.build.Revision,
		ConfigDigest: s.opts.ConfigIdentity.Digest,
		Config:       s.opts.ConfigIdentity,
	})
	if err != nil {
		// Unreachable for this struct (every field is a string or an int),
		// but a liveness probe must never emit a half-written body: a
		// truncated JSON object reads as a malformed response, which some
		// probes treat as UP.
		http.Error(w, `{"status":"error"}`, http.StatusInternalServerError)
		return
	}
	_, _ = w.Write(body)
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

	// -- outbox log compaction ----------------------------------------------
	compactRuns, compactDropped, compactBytes := 0, 0, int64(0)
	if s.opts.Outbox != nil {
		compactRuns, compactDropped, compactBytes = s.opts.Outbox.CompactionStats()
	}

	writeMetric(w, "svc_outbox_compactions_total", "counter",
		"Boot compactions of the durable outbox log. Compaction is BOOT-ONLY, so this climbs with restarts rather than with traffic -- a value that stops climbing while the process is alive is normal, and one stuck at 0 across many restarts means compaction is not running at all.",
		"", float64(compactRuns))

	writeMetric(w, "svc_outbox_compacted_entries_total", "counter",
		"Outbox entries folded away by compaction: terminal AND no longer re-derivable from the event log. Read against the reclaimed-bytes series -- entries dropping while bytes stay flat means the log is dominated by entries compaction must KEEP.",
		"", float64(compactDropped))

	writeMetric(w, "svc_outbox_compaction_reclaimed_bytes_total", "counter",
		"Bytes reclaimed by boot compaction. Zero across repeated restarts while the outbox log grows on disk is exactly the condition the mechanism exists to prevent: boot replay cost climbing with lifetime effect volume instead of with the live set.",
		"", float64(compactBytes))

	// -- telemetry export health --------------------------------------------
	var exportFailures int64
	if s.opts.OTLPExportFailures != nil {
		exportFailures = s.opts.OTLPExportFailures()
	}
	writeMetric(w, "svc_otlp_export_failures_total", "counter",
		"OTLP exports that failed, across every signal (traces, and logs when LOG_EXPORT=otlp -- the OpenTelemetry error handler they share does not distinguish them). Non-zero means telemetry is being DROPPED while the service itself is unaffected, so this is a warn, never a page. Climbing while the service is healthy is the one condition under which a dashboard showing nothing wrong means nothing at all.",
		"", float64(exportFailures))
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
		"svc_outbox_compactions_total",
		"svc_outbox_compacted_entries_total",
		"svc_outbox_compaction_reclaimed_bytes_total",
		"svc_otlp_export_failures_total",
	}
	sort.Strings(names)
	return names
}
