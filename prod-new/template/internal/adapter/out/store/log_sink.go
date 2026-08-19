package store

import (
	"context"
	"fmt"
	"log/slog"
)

// LogSink is the template's real, working, dependency-free Sink: it
// "delivers" by emitting a structured slog line. It is a legitimate
// end-to-end demonstration of the outbox pattern (Journal -> Publish ->
// Deliver -> mark done, with a real idempotency key threaded through), not
// a stub -- swap it for an HTTP/webhook/queue Sink without touching
// Outbox, Ledger, or any test that exercises the pattern itself.
type LogSink struct {
	logger *slog.Logger
	// FailUntilAttempt, when > 0, makes Deliver fail for every idempotency
	// key it has not yet seen succeed until it has been called
	// FailUntilAttempt times FOR THAT KEY -- a deterministic, injectable
	// flakiness knob so tests (and the conformance kit's retry/timeout/
	// extreme_latency scenarios) can drive real retry behavior without a
	// network dependency. Zero (the default) never fails.
	FailUntilAttempt int

	attempts map[string]int
}

// NewLogSink returns a LogSink logging through logger (slog.Default() if
// nil).
func NewLogSink(logger *slog.Logger) *LogSink {
	if logger == nil {
		logger = slog.Default()
	}
	return &LogSink{logger: logger, attempts: map[string]int{}}
}

// Deliver implements Sink.
func (s *LogSink) Deliver(ctx context.Context, idempotencyKey string, entry Entry) error {
	if s.attempts == nil {
		s.attempts = map[string]int{}
	}
	s.attempts[idempotencyKey]++
	if s.FailUntilAttempt > 0 && s.attempts[idempotencyKey] < s.FailUntilAttempt {
		return fmt.Errorf("logsink: simulated failure (attempt %d/%d for key %s)", s.attempts[idempotencyKey], s.FailUntilAttempt, idempotencyKey)
	}
	s.logger.InfoContext(ctx, "outbox delivery",
		"idempotency_key", idempotencyKey,
		"entry_id", entry.ID,
		"effect", fmt.Sprintf("%#v", entry.Effect),
		"attempt", entry.Attempts,
	)
	return nil
}

// AttemptsFor returns how many times Deliver has been called for the given
// idempotency key -- used by tests to assert the SAME key was reused across
// physical retries within one logical Publish call.
func (s *LogSink) AttemptsFor(idempotencyKey string) int {
	return s.attempts[idempotencyKey]
}
