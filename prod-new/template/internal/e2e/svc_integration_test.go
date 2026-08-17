//go:build integration

// Package e2e holds the integration-real-lane: a test that puts a REAL TCP
// listener, a real filesystem-backed event log, and real HTTP traffic
// between the pieces the composition root (cmd/<SERVICE>) wires together --
// instead of every other test in this module's in-process/bufconn-style
// hermetic style. Tagged `integration` so it stays out of the default
// `go test ./...` path (and therefore check-fast/verify); `make e2e` and
// the PR workflow's `e2e-real` job are what run it.
package e2e

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"path/filepath"
	"testing"

	"github.com/<OWNER>/<SERVICE>/internal/adapter/in/healthhttp"
	"github.com/<OWNER>/<SERVICE>/internal/adapter/out/store"
	"github.com/<OWNER>/<SERVICE>/internal/app"
	"github.com/<OWNER>/<SERVICE>/internal/platform/clock"
	"github.com/<OWNER>/<SERVICE>/internal/platform/eventlog"
	"github.com/<OWNER>/<SERVICE>/internal/platform/ids"
)

// provenance: derived
// verifies: integration fidelity (tier-policy: integration_fidelity =
// hermetic_plus_one_real -- at least one lane against a REAL dependency,
// here a real TCP socket + a real on-disk event log, mirroring exactly how
// cmd/<SERVICE>'s composition root wires the same pieces together)
func TestSvc_RealEventLogAndRealTCP_DepositAndWithdrawSurviveARestart(t *testing.T) {
	logPath := filepath.Join(t.TempDir(), "eventlog.jsonl")

	// -- "boot 1": deposit, withdraw, observe the real HTTP surface --------
	ledger1, log1, cleanup1 := bootRealLedger(t, logPath)
	if _, err := ledger1.Deposit(context.Background(), "e1", "10"); err != nil {
		t.Fatalf("Deposit: %v", err)
	}
	if _, err := ledger1.Withdraw(context.Background(), "e2", "3"); err != nil {
		t.Fatalf("Withdraw: %v", err)
	}
	if got := ledger1.State().Balance; got != "7.00000000" {
		t.Fatalf("balance after boot 1 = %q, want 7.00000000", got)
	}

	srv := healthhttp.New(ledger1, healthhttp.Options{Log: log1})
	lis, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	go func() { _ = srv.ServeListener(ctx, lis) }()

	resp, err := http.Get("http://" + lis.Addr().String() + "/readyz")
	if err != nil {
		t.Fatalf("get /readyz over real TCP: %v", err)
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("/readyz over real TCP = %d, want 200", resp.StatusCode)
	}
	var body struct {
		Ready bool `json:"ready"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode /readyz body: %v", err)
	}
	if !body.Ready {
		t.Fatal("/readyz over real TCP reported not ready")
	}
	cancel()
	cleanup1()

	// -- "boot 2": a fresh process replays the SAME on-disk log -------------
	ledger2, _, cleanup2 := bootRealLedger(t, logPath)
	defer cleanup2()
	if got := ledger2.State().Balance; got != "7.00000000" {
		t.Fatalf("balance after replaying the real on-disk log on a fresh boot = %q, want 7.00000000 (recovery semantics: rebuild from the log)", got)
	}
}

func bootRealLedger(t *testing.T, logPath string) (*app.Ledger, *eventlog.Log, func()) {
	t.Helper()
	log, err := eventlog.Open(logPath)
	if err != nil {
		t.Fatalf("eventlog.Open: %v", err)
	}
	past, err := eventlog.Replay(logPath)
	if err != nil {
		t.Fatalf("eventlog.Replay: %v", err)
	}
	initial := eventlog.Rebuild(past)
	outbox := store.NewOutbox(store.NewLogSink(nil), ids.Real{}.NewID, 3)
	ledger := app.NewLedger(initial, log, outbox, clock.Real{}.Now, ids.Real{}.NewID)
	return ledger, log, func() { _ = log.Close() }
}
