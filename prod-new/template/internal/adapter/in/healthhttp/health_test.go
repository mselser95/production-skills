package healthhttp

import (
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/<OWNER>/<SERVICE>/internal/platform/config"
)

// fakeLedger is a test double for LedgerHealth.
type fakeLedger struct {
	conservation, duplicate int64
	lastViolation           time.Time
}

func (f fakeLedger) ConservationViolations() int64       { return f.conservation }
func (f fakeLedger) DuplicateEffectViolations() int64    { return f.duplicate }
func (f fakeLedger) LastInvariantViolationAt() time.Time { return f.lastViolation }

// fakeLog is a test double for EventLogHealth.
type fakeLog struct{ writable bool }

func (f fakeLog) Writable() bool { return f.writable }

// serveTest starts srv on a real TCP loopback listener and returns the base
// URL. Bind-and-hand-over: never close-then-rebind, which races another
// parallel test for the port.
func serveTest(t *testing.T, srv *Server) string {
	t.Helper()
	lis, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go func() { _ = srv.ServeListener(ctx, lis) }()
	return "http://" + lis.Addr().String()
}

// provenance: derived
// verifies: /healthz serves build identity + config digest (operational
// determinism)
func TestHealthz_ServesBuildIdentity(t *testing.T) {
	srv := New(fakeLedger{}, Options{PodID: "pod-1", ConfigIdentity: config.Identity{Digest: "abc123"}})
	base := serveTest(t, srv)

	resp, err := http.Get(base + "/healthz")
	if err != nil {
		t.Fatalf("get /healthz: %v", err)
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}
	var body struct {
		Status       string `json:"status"`
		PodID        string `json:"pod_id"`
		ConfigDigest string `json:"config_digest"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if body.Status != "ok" || body.PodID != "pod-1" || body.ConfigDigest != "abc123" {
		t.Fatalf("body = %+v, want status=ok pod_id=pod-1 config_digest=abc123", body)
	}
}

// provenance: derived
// verifies: /readyz multi-gate (no log -> not ready)
func TestReadyz_NoLogIsNotReady(t *testing.T) {
	srv := New(fakeLedger{}, Options{})
	base := serveTest(t, srv)
	assertNotReady(t, base)
}

// provenance: derived
// verifies: /readyz multi-gate (writable log + no violation -> ready)
func TestReadyz_WritableLogNoViolation_IsReady(t *testing.T) {
	srv := New(fakeLedger{}, Options{Log: fakeLog{writable: true}})
	base := serveTest(t, srv)

	resp, err := http.Get(base + "/readyz")
	if err != nil {
		t.Fatalf("get /readyz: %v", err)
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}
}

// provenance: ratified
// verifies: readiness gate honors the invariant-violation cooldown --
// evaluated via ReadinessAt(now) so an arbitrary `now` (not the wall clock)
// drives the freshness comparison, exactly like the stale-tick pattern this
// template's reference implementation used for its own ratified invariant.
func TestReadinessAt_RecentViolationGatesReadiness_ThenClearsAfterCooldown(t *testing.T) {
	violatedAt := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	srv := New(fakeLedger{lastViolation: violatedAt}, Options{Log: fakeLog{writable: true}, ViolationCooldown: time.Minute})

	readyImmediately, checksImmediately := srv.ReadinessAt(violatedAt.Add(time.Second))
	if readyImmediately || checksImmediately.NoRecentInvariantViolation {
		t.Fatalf("ready=%v checks=%+v immediately after a violation, want not-ready", readyImmediately, checksImmediately)
	}

	readyLater, checksLater := srv.ReadinessAt(violatedAt.Add(2 * time.Minute))
	if !readyLater || !checksLater.NoRecentInvariantViolation {
		t.Fatalf("ready=%v checks=%+v after the cooldown elapsed, want ready", readyLater, checksLater)
	}
}

func assertNotReady(t *testing.T, base string) {
	t.Helper()
	resp, err := http.Get(base + "/readyz")
	if err != nil {
		t.Fatalf("get /readyz: %v", err)
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503", resp.StatusCode)
	}
}

// provenance: derived
// verifies: /metrics serves hand-rolled Prometheus text with no client
// library dependency
func TestMetrics_ServesPrometheusText(t *testing.T) {
	srv := New(fakeLedger{conservation: 2, duplicate: 1}, Options{Log: fakeLog{writable: true}})
	base := serveTest(t, srv)

	resp, err := http.Get(base + "/metrics")
	if err != nil {
		t.Fatalf("get /metrics: %v", err)
	}
	defer func() { _ = resp.Body.Close() }()
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	body := string(raw)
	for _, want := range []string{
		"svc_build_info",
		"svc_units_conserved_violations_total",
		"svc_duplicate_event_violations_total",
		"svc_eventlog_writable",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("scrape missing series %q\n%s", want, body)
		}
	}
	if !strings.Contains(body, "svc_units_conserved_violations_total 2") {
		t.Errorf("conservation violations value not rendered as 2:\n%s", body)
	}
}
