package main

import (
	"errors"
	"testing"

	"context"
	"fmt"
	"github.com/<OWNER>/<SERVICE>/internal/domain"
	"github.com/<OWNER>/<SERVICE>/internal/platform/eventlog"
	"github.com/<OWNER>/<SERVICE>/internal/platform/observability"
	"log/slog"
	"os"
	"path/filepath"
	"time"
)

// provenance: derived
// verifies: composition root (portAddr's ephemeral-vs-fixed port selection,
// the one piece of this file with a return value worth pinning directly --
// the rest of main() is process-wiring glue exercised end to end by
// internal/e2e's integration-tagged test instead, per the standard's own
// "don't pad coverage on process glue" discipline)
func TestPortAddr(t *testing.T) {
	if got := portAddr(0); got != "127.0.0.1:0" {
		t.Fatalf("portAddr(0) = %q, want 127.0.0.1:0", got)
	}
	if got := portAddr(9090); got != ":9090" {
		t.Fatalf("portAddr(9090) = %q, want :9090", got)
	}
}

// provenance: derived
// verifies: the composition root's ONE piece of real bridging logic --
// adaptTracer -- correctly wires observability.Tracer's StartSpan/End/
// RecordError into internal/app.SpanFunc's shape, in both the success and
// error case, so an error passed to the returned func actually reaches the
// underlying Span.RecordError before End is called.
func TestAdaptTracer(t *testing.T) {
	rec := observability.NewRecording()
	spanFn := adaptTracer(rec)

	end := spanFn("svc.deposit", map[string]string{"event_type": "deposited"})
	end(nil)

	end2 := spanFn("svc.withdraw", map[string]string{"event_type": "withdrawn"})
	end2(errors.New("boom"))

	deposits := rec.Named("svc.deposit")
	if len(deposits) != 1 || deposits[0].Err != nil {
		t.Fatalf("svc.deposit span = %+v, want one span with no error", deposits)
	}
	withdrawals := rec.Named("svc.withdraw")
	if len(withdrawals) != 1 || withdrawals[0].Err == nil {
		t.Fatalf("svc.withdraw span = %+v, want one span with a recorded error", withdrawals)
	}
}

// provenance: derived
// verifies: snapshotLoop actually snapshots and compacts once the replay
// tail crosses its threshold, and stops on context cancellation.
//
// This loop is the only thing keeping boot time and disk usage bounded, and
// it is the kind of background goroutine that silently does nothing --
// wrong threshold, wrong counter, never scheduled -- while the service looks
// perfectly healthy right up until a restart takes minutes. The assertion
// that matters is the one on Recover's stats: after the loop runs, recovery
// must replay a SHORT tail rather than the whole history.
func TestSnapshotLoop_CollapsesTheReplayTail(t *testing.T) {
	path := filepath.Join(t.TempDir(), "eventlog.jsonl")
	log, err := eventlog.Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer func() { _ = log.Close() }()

	const events = 25
	for i := 0; i < events; i++ {
		e := domain.Event{ID: fmt.Sprintf("e%d", i), Type: domain.EventDeposited, Amount: "1"}
		if err := log.Append(e); err != nil {
			t.Fatalf("Append: %v", err)
		}
	}
	// Before the loop runs, a boot would replay every single event.
	if _, stats, err := eventlog.Recover(path); err != nil {
		t.Fatalf("Recover: %v", err)
	} else if stats.EventsReplayed != events {
		t.Fatalf("precondition: EventsReplayed = %d, want %d", stats.EventsReplayed, events)
	}

	state := func() domain.State {
		s, _, err := eventlog.Recover(path)
		if err != nil {
			t.Errorf("Recover inside state(): %v", err)
		}
		return s
	}

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		snapshotLoop(ctx, log, state, slog.Default(), 5*time.Millisecond, 10)
	}()

	deadline := time.After(10 * time.Second)
	for {
		_, stats, err := eventlog.Recover(path)
		if err != nil {
			t.Fatalf("Recover: %v", err)
		}
		if stats.SnapshotFound && stats.EventsReplayed == 0 {
			break
		}
		select {
		case <-deadline:
			cancel()
			t.Fatalf("snapshotLoop never collapsed the tail: SnapshotFound=%v EventsReplayed=%d",
				stats.SnapshotFound, stats.EventsReplayed)
		case <-time.After(10 * time.Millisecond):
		}
	}

	cancel()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("snapshotLoop did not return after its context was cancelled -- shutdown would hang")
	}
}

// provenance: derived
// verifies: snapshotLoop leaves a SHORT log behind, not just a snapshot.
// Snapshotting without compacting bounds boot time while letting the disk
// grow forever, which is half the fix wearing the whole fix's name.
func TestSnapshotLoop_CompactsSoTheLogStopsGrowing(t *testing.T) {
	path := filepath.Join(t.TempDir(), "eventlog.jsonl")
	log, err := eventlog.Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer func() { _ = log.Close() }()

	for i := 0; i < 40; i++ {
		if err := log.Append(domain.Event{
			ID: fmt.Sprintf("e%d", i), Type: domain.EventDeposited, Amount: "1",
		}); err != nil {
			t.Fatalf("Append: %v", err)
		}
	}
	sizeBefore := fileSize(t, path)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go snapshotLoop(ctx, log, func() domain.State {
		s, _, _ := eventlog.Recover(path)
		return s
	}, slog.Default(), 5*time.Millisecond, 10)

	deadline := time.After(10 * time.Second)
	for fileSize(t, path) >= sizeBefore {
		select {
		case <-deadline:
			t.Fatalf("log never shrank: still %d bytes (was %d) -- snapshots are being "+
				"written but nothing reclaims the history they subsume",
				fileSize(t, path), sizeBefore)
		case <-time.After(10 * time.Millisecond):
		}
	}
}

func fileSize(t *testing.T, path string) int64 {
	t.Helper()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat %s: %v", path, err)
	}
	return info.Size()
}

// provenance: derived
// verifies: a failing snapshot does not kill the loop.
//
// The loop is the only thing bounding boot time, so it has to be the most
// boring goroutine in the process: a snapshot that fails must be logged and
// retried on the next tick, never returned on. A loop that exits on its
// first error looks identical to a healthy one -- until a restart replays
// everything since the day it quit.
func TestSnapshotLoop_SurvivesAFailingSnapshot(t *testing.T) {
	path := filepath.Join(t.TempDir(), "eventlog.jsonl")
	log, err := eventlog.Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	for i := 0; i < 15; i++ {
		if err := log.Append(domain.Event{
			ID: fmt.Sprintf("e%d", i), Type: domain.EventDeposited, Amount: "1",
		}); err != nil {
			t.Fatalf("Append: %v", err)
		}
	}
	// Closing the log makes every Snapshot attempt fail from here on.
	if err := log.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		snapshotLoop(ctx, log, domain.NewState, slog.Default(), 2*time.Millisecond, 1)
	}()

	// Give it many ticks to exit on error if it is going to.
	time.Sleep(80 * time.Millisecond)
	select {
	case <-done:
		t.Fatal("snapshotLoop returned after a failed snapshot -- the service would run " +
			"on with nothing bounding its boot time, looking perfectly healthy")
	default:
	}

	cancel()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("snapshotLoop did not return after cancellation")
	}
}
