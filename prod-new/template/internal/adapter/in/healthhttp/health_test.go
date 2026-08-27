package healthhttp

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net"
	"net/http"
	"reflect"
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

// provenance: regression
// verifies: /healthz surfaces EVERY field of config.Identity, compared
// against the struct's own JSON tags rather than a hand-written list.
//
// THE DRIFT THIS CATCHES ALREADY HAPPENED. config.Identity was built to
// answer "which config produced this result" and docs/RUNBOOK.md told
// operators to read `tracing`, `log_level` and `log_export` off /healthz --
// while the handler printed four string literals and consumed the struct only
// for `.Digest`. The endpoint had never surfaced a single one of those
// fields, and no test noticed, because every test named the fields it
// expected.
//
// So this one names NONE of them: it reflects over config.Identity's JSON
// tags and requires each to appear in the response. A field added to Identity
// and forgotten here fails immediately, which is the only version of this
// check that survives the next person.
func TestHealthz_SurfacesEveryConfigIdentityField(t *testing.T) {
	identity := config.Config{
		Tracing:                    config.TracingOTLP,
		TracingEndpoint:            "tempo:4318",
		LogLevel:                   slog.LevelWarn,
		LogExport:                  config.LogExportOTLP,
		OutboxMaxAttempts:          7,
		PprofPort:                  6060,
		InvariantViolationCooldown: 42 * time.Second,
	}.Identity()

	srv := New(fakeLedger{}, Options{PodID: "pod-1", ConfigIdentity: identity})
	base := serveTest(t, srv)

	resp, err := http.Get(base + "/healthz")
	if err != nil {
		t.Fatalf("get /healthz: %v", err)
	}
	defer func() { _ = resp.Body.Close() }()

	var body struct {
		Config map[string]any `json:"config"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}

	typ := reflect.TypeOf(identity)
	for i := 0; i < typ.NumField(); i++ {
		tag := strings.Split(typ.Field(i).Tag.Get("json"), ",")[0]
		if tag == "" || tag == "-" {
			t.Fatalf("config.Identity.%s has no json tag, so it can never reach /healthz", typ.Field(i).Name)
		}
		if _, ok := body.Config[tag]; !ok {
			t.Errorf("/healthz does not surface config.Identity field %q (%s) -- "+
				"docs/RUNBOOK.md tells operators to read it off this endpoint",
				tag, typ.Field(i).Name)
		}
	}

	// Spot-check the two the runbook's tracing procedure depends on, so a
	// response that carried the KEYS with empty values would still fail.
	if body.Config["tracing"] != config.TracingOTLP {
		t.Fatalf("config.tracing = %v, want %q", body.Config["tracing"], config.TracingOTLP)
	}
	if body.Config["tracing_endpoint"] != "tempo:4318" {
		t.Fatalf("config.tracing_endpoint = %v, want tempo:4318 -- "+
			"'is this pod exporting, and to where' must be a lookup", body.Config["tracing_endpoint"])
	}
}

// provenance: derived
// verifies: /healthz surfaces the reconstructed ledger state, so a crash-only
// recovery claim (Candea & Fox, HotOS IX 2003) is falsifiable from OUTSIDE
// the process -- the assertion scripts/kill-durability.sh makes across a real
// SIGKILL
func TestHealthz_SurfacesTheReconstructedLedgerState(t *testing.T) {
	srv := New(fakeLedger{}, Options{
		LedgerState: func() (string, int, string) { return "42", 3, "d1d2d3d4d5d6" },
	})
	base := serveTest(t, srv)

	resp, err := http.Get(base + "/healthz")
	if err != nil {
		t.Fatalf("get /healthz: %v", err)
	}
	defer func() { _ = resp.Body.Close() }()

	var body struct {
		State LedgerStateView `json:"state"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if !body.State.Known {
		t.Fatalf("state.known = false with a LedgerState supplied -- a probe cannot tell "+
			"'no ledger' from 'empty ledger', which is the ambiguity the field exists to remove: %+v", body.State)
	}
	if body.State.Balance != "42" || body.State.AppliedCount != 3 || body.State.AppliedDigest != "d1d2d3d4d5d6" {
		t.Fatalf("state = %+v, want balance=42 applied_count=3 applied_digest=d1d2d3d4d5d6", body.State)
	}
}

// provenance: derived
// verifies: /healthz distinguishes "no ledger" from "empty ledger"
//
// The negative half, and it carries the same weight as the positive one: a
// handler that always rendered known=true would pass the test above, and
// scripts/kill-durability.sh would then compare two IDENTICAL EMPTY captures
// across the kill and report crash-only recovery proven having observed
// nothing. That is exactly the vacuous pass this standard keeps finding, so
// it gets its own case rather than a comment.
func TestHealthz_LedgerStateIsMarkedUnknownWhenThereIsNoLedger(t *testing.T) {
	srv := New(fakeLedger{}, Options{})
	base := serveTest(t, srv)

	resp, err := http.Get(base + "/healthz")
	if err != nil {
		t.Fatalf("get /healthz: %v", err)
	}
	defer func() { _ = resp.Body.Close() }()

	var body struct {
		State LedgerStateView `json:"state"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if body.State.Known {
		t.Fatalf("state.known = true with no LedgerState supplied: %+v", body.State)
	}
	if body.State.Balance != "" || body.State.AppliedCount != 0 || body.State.AppliedDigest != "" {
		t.Fatalf("state = %+v, want the zero view when nothing supplies it", body.State)
	}
}
