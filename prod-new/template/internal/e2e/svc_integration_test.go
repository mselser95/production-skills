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
	"github.com/<OWNER>/<SERVICE>/internal/platform/relay"
)

// provenance: derived
// verifies: integration fidelity (tier-policy: integration_fidelity =
// hermetic_plus_one_real -- at least one lane against a REAL dependency,
// here a real TCP socket + a real on-disk event log, mirroring exactly how
// cmd/<SERVICE>'s composition root wires the same pieces together)
func TestSvc_RealEventLogAndRealTCP_DepositAndWithdrawSurviveARestart(t *testing.T) {
	dir := t.TempDir()

	// -- "boot 1": deposit, withdraw, observe the real HTTP surface --------
	boot1, cleanup1 := bootRealLedger(t, dir)
	if _, err := boot1.ledger.Deposit(context.Background(), "e1", "10"); err != nil {
		t.Fatalf("Deposit: %v", err)
	}
	if _, err := boot1.ledger.Withdraw(context.Background(), "e2", "3"); err != nil {
		t.Fatalf("Withdraw: %v", err)
	}
	if got := boot1.ledger.State().Balance; got != "7.00000000" {
		t.Fatalf("balance after boot 1 = %q, want 7.00000000", got)
	}

	// The relay reads the SAME on-disk log the ledger just wrote, with no
	// second store between them, and publishes both facts -- including the
	// withdrawal, which a mapper that re-derives effects from a fresh state
	// silently drops.
	if err := boot1.relay.RunToEnd(context.Background()); err != nil {
		t.Fatalf("relay drain on boot 1: %v", err)
	}
	delivered := boot1.pub.Delivered()
	if len(delivered) != 2 || delivered[0].ID != "e1" || delivered[1].ID != "e2" {
		t.Fatalf("relay delivered %+v, want e1 then e2 over the real on-disk log", delivered)
	}
	if lag, err := boot1.relay.Lag(context.Background()); err != nil || lag != 0 {
		t.Fatalf("relay lag = %d, %v; want 0, nil", lag, err)
	}

	srv := healthhttp.New(boot1.ledger, healthhttp.Options{Log: boot1.log})
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
	boot2, cleanup2 := bootRealLedger(t, dir)
	defer cleanup2()
	if got := boot2.ledger.State().Balance; got != "7.00000000" {
		t.Fatalf("balance after replaying the real on-disk log on a fresh boot = %q, want 7.00000000 (recovery semantics: rebuild from the log)", got)
	}

	// The restarted relay reads the checkpoint boot 1 left on disk and
	// republishes NOTHING. A restart that floods downstream with the whole
	// history is what a non-durable checkpoint produces, and it looks like a
	// clean boot from every other angle.
	if err := boot2.relay.RunToEnd(context.Background()); err != nil {
		t.Fatalf("relay drain on boot 2: %v", err)
	}
	if n := len(boot2.pub.Delivered()); n != 0 {
		t.Fatalf("restart republished %d messages over the real checkpoint file, want 0", n)
	}

	// A fact recorded after the restart is picked up from the stored
	// position, so the checkpoint resumed rather than merely suppressed.
	if _, err := boot2.ledger.Deposit(context.Background(), "e3", "5"); err != nil {
		t.Fatalf("post-restart Deposit: %v", err)
	}
	if err := boot2.relay.RunToEnd(context.Background()); err != nil {
		t.Fatalf("post-restart relay drain: %v", err)
	}
	if d := boot2.pub.Delivered(); len(d) != 1 || d[0].ID != "e3" {
		t.Fatalf("post-restart relay delivered %+v, want only e3", d)
	}
}

// realBoot is one simulated process: the same pieces cmd/<SERVICE>'s
// composition root wires, over a real on-disk log and a real on-disk relay
// checkpoint.
type realBoot struct {
	ledger *app.Ledger
	log    *eventlog.Log
	relay  *relay.Relay[eventlog.SeqEvent]
	pub    *store.LogPublisher
}

func bootRealLedger(t *testing.T, dir string) (*realBoot, func()) {
	t.Helper()
	logPath := filepath.Join(dir, "eventlog.jsonl")

	log, err := eventlog.Open(logPath)
	if err != nil {
		t.Fatalf("eventlog.Open: %v", err)
	}
	past, err := eventlog.Replay(logPath)
	if err != nil {
		t.Fatalf("eventlog.Replay: %v", err)
	}
	initial := eventlog.Rebuild(past)

	cps, err := relay.OpenCheckpoints(filepath.Join(dir, "checkpoints.json"))
	if err != nil {
		t.Fatalf("relay.OpenCheckpoints: %v", err)
	}
	pub := store.NewLogPublisher(nil)
	rel, err := relay.New[eventlog.SeqEvent](log, cps, store.EnvelopeMapper("svc.events"), pub, nil,
		relay.Options{Name: "publisher"})
	if err != nil {
		t.Fatalf("relay.New: %v", err)
	}

	ledger := app.NewLedger(initial, log, rel.Notify, clock.Real{}.Now, ids.Real{}.NewID)
	return &realBoot{ledger: ledger, log: log, relay: rel, pub: pub}, func() { _ = log.Close() }
}
