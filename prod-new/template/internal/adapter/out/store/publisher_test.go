package store

import (
	"context"
	"encoding/json"
	"strconv"
	"sync"
	"testing"

	"github.com/<OWNER>/<SERVICE>/internal/domain"
	"github.com/<OWNER>/<SERVICE>/internal/platform/eventlog"
	"github.com/<OWNER>/<SERVICE>/internal/platform/relay"
)

func mustMap(t *testing.T, se eventlog.SeqEvent) []relay.Publication {
	t.Helper()
	pubs, err := EnvelopeMapper("svc.events")(se)
	if err != nil {
		t.Fatalf("EnvelopeMapper: %v", err)
	}
	return pubs
}

// provenance: regression
// verifies: an admitted WITHDRAWAL is published
//
// This template previously derived the publication by re-folding the event
// against a fresh domain.State. A withdrawal of 5 against a zero balance is
// rejected, so the mapper produced zero publications and every withdrawal was
// silently dropped -- committed in the ledger, never announced. The mapper now
// translates the event directly, which is correct because internal/app only
// journals events the domain ADMITTED.
//
// Non-vacuity: restore the re-fold (_, effects := domain.Apply(domain.NewState(),
// se.Event); switch on the effects) and this test goes RED with 0 publications.
func TestEnvelopeMapper_AdmittedWithdrawalIsPublished(t *testing.T) {
	pubs := mustMap(t, eventlog.SeqEvent{
		Seq:   7,
		Event: domain.Event{ID: "w1", Type: domain.EventWithdrawn, Amount: "5"},
	})
	if len(pubs) != 1 {
		t.Fatalf("publications = %d, want 1 -- a committed withdrawal that is never "+
			"published is silent data loss at the integration boundary", len(pubs))
	}
	var n notification
	if err := json.Unmarshal(pubs[0].Msg.Payload, &n); err != nil {
		t.Fatalf("payload: %v", err)
	}
	if n.Type != "units.withdrawn" || n.EventID != "w1" || n.Amount != "5" {
		t.Fatalf("notification = %+v", n)
	}
}

// provenance: derived
// verifies: a deposit maps to exactly one publication carrying the event's
// own id, type and amount
func TestEnvelopeMapper_DepositCarriesTheEventIdentity(t *testing.T) {
	pubs := mustMap(t, eventlog.SeqEvent{
		Seq:   3,
		Event: domain.Event{ID: "d1", Type: domain.EventDeposited, Amount: "10"},
	})
	if len(pubs) != 1 {
		t.Fatalf("publications = %d, want 1", len(pubs))
	}
	if pubs[0].Topic != "svc.events" {
		t.Fatalf("topic = %q", pubs[0].Topic)
	}
	// The message id IS the persisted event id. A fresh id per attempt would
	// present a redelivery as a brand-new fact.
	if pubs[0].Msg.ID != "d1" {
		t.Fatalf("message id = %q, want the event id d1", pubs[0].Msg.ID)
	}
}

// provenance: derived
// verifies: the envelope metadata carries every field a consumer needs to
// deduplicate, order and version WITHOUT unmarshaling the payload
func TestEnvelopeMapper_MetadataIsComplete(t *testing.T) {
	pubs := mustMap(t, eventlog.SeqEvent{
		Seq:        12,
		Origin:     eventlog.OriginIngested,
		ForeignSeq: 44,
		Event:      domain.Event{ID: "d1", Type: domain.EventDeposited, Amount: "10"},
	})
	md := pubs[0].Msg.Metadata
	want := map[string]string{
		MetaEventID:    "d1",
		MetaEventType:  string(domain.EventDeposited),
		MetaPosition:   "12",
		MetaOrigin:     string(eventlog.OriginIngested),
		MetaForeignSeq: "44",
		MetaSchema:     IntegrationSchema,
	}
	for k, v := range want {
		if md[k] != v {
			t.Errorf("metadata[%q] = %q, want %q", k, md[k], v)
		}
	}
	// The position must be the LOCAL sequence, not the foreign one: a
	// consumer ordering on it would otherwise interleave ingested and raised
	// events by two unrelated clocks.
	if p, err := strconv.ParseInt(md[MetaPosition], 10, 64); err != nil || p != 12 {
		t.Fatalf("position metadata = %q, want the local seq 12", md[MetaPosition])
	}
}

// provenance: derived
// verifies: an event type this build does not publish maps to NOTHING rather
// than to an invented shape -- and the relay is free to advance past it
func TestEnvelopeMapper_UnknownTypePublishesNothing(t *testing.T) {
	pubs := mustMap(t, eventlog.SeqEvent{Seq: 1, Event: domain.Event{ID: "x", Type: domain.EventType("svc.unheard-of")}})
	if len(pubs) != 0 {
		t.Fatalf("publications = %d, want 0 for an unknown event type", len(pubs))
	}
}

// provenance: derived
// verifies: the published payload is the INTEGRATION contract, not the
// domain type -- so renaming a domain field cannot silently change what
// consumers parse
func TestEnvelopeMapper_PayloadIsTheIntegrationContract(t *testing.T) {
	pubs := mustMap(t, eventlog.SeqEvent{Seq: 1, Event: domain.Event{ID: "d1", Type: domain.EventDeposited, Amount: "1"}})
	var raw map[string]any
	if err := json.Unmarshal(pubs[0].Msg.Payload, &raw); err != nil {
		t.Fatalf("payload: %v", err)
	}
	for _, k := range []string{"type", "event_id", "amount"} {
		if _, ok := raw[k]; !ok {
			t.Errorf("payload is missing the contract field %q: %v", k, raw)
		}
	}
	if len(raw) != 3 {
		t.Fatalf("payload has %d fields (%v), want exactly the 3 contract fields -- "+
			"an extra field here is a contract change no consumer asked for", len(raw), raw)
	}
}

// provenance: derived
// verifies: LogPublisher confirms SYNCHRONOUSLY -- the message is recorded
// before Publish returns, which is the property the relay's no-loss ordering
// depends on
func TestLogPublisher_ConfirmsBeforeReturning(t *testing.T) {
	p := NewLogPublisher(nil)
	if err := p.Publish(context.Background(), "t", relay.Message{ID: "m1"}); err != nil {
		t.Fatalf("Publish: %v", err)
	}
	if got := p.Delivered(); len(got) != 1 || got[0].ID != "m1" {
		t.Fatalf("Delivered = %+v, want m1 already recorded when Publish returned", got)
	}
}

// provenance: derived
// verifies: the injected fault is deterministic and per-message-ID, so a
// retry test drives real retry behaviour rather than a coin flip
func TestLogPublisher_FailUntilIsDeterministicPerID(t *testing.T) {
	p := NewLogPublisher(nil)
	p.FailUntil = 3
	ctx := context.Background()
	for i := 1; i < 3; i++ {
		if err := p.Publish(ctx, "t", relay.Message{ID: "m1"}); err == nil {
			t.Fatalf("attempt %d succeeded, want a failure until attempt 3", i)
		}
	}
	if err := p.Publish(ctx, "t", relay.Message{ID: "m1"}); err != nil {
		t.Fatalf("attempt 3: %v", err)
	}
	if p.AttemptsFor("m1") != 3 {
		t.Fatalf("attempts = %d, want 3", p.AttemptsFor("m1"))
	}
	// A different id has its own budget: failures are not global.
	if err := p.Publish(ctx, "t", relay.Message{ID: "m2"}); err == nil {
		t.Fatal("m2 succeeded on its first attempt despite FailUntil=3")
	}
}

// provenance: derived
// verifies: Delivered returns a COPY, so a caller cannot mutate the
// publisher's record of what it sent
func TestLogPublisher_DeliveredIsACopy(t *testing.T) {
	p := NewLogPublisher(nil)
	if err := p.Publish(context.Background(), "t", relay.Message{ID: "m1"}); err != nil {
		t.Fatalf("Publish: %v", err)
	}
	got := p.Delivered()
	got[0].ID = "tampered"
	if again := p.Delivered(); again[0].ID != "m1" {
		t.Fatalf("Delivered leaked its backing array: %q", again[0].ID)
	}
}

// provenance: derived
// verifies: LogPublisher is safe under concurrent publishes (the relay is
// single-threaded today, but a fan-out publisher is the obvious next change
// and an unsynchronised map would be a race, not an error)
func TestLogPublisher_ConcurrentPublishIsRaceFree(t *testing.T) {
	p := NewLogPublisher(nil)
	var wg sync.WaitGroup
	for i := 0; i < 64; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			_ = p.Publish(context.Background(), "t", relay.Message{ID: strconv.Itoa(i)})
		}(i)
	}
	wg.Wait()
	if got := len(p.Delivered()); got != 64 {
		t.Fatalf("delivered %d, want 64", got)
	}
}

// --- end-to-end: the log IS the outbox ----------------------------------

// provenance: derived
// verifies: the whole path -- events appended to a real eventlog are read by
// a real relay, mapped, published, and checkpointed; a restart republishes
// nothing already delivered
//
// This is the claim the separate outbox used to make and could not keep: no
// second store, no atomicity window between two writes, and the delivery
// position is the only extra durable fact.
func TestEndToEnd_EventLogIsTheOutbox(t *testing.T) {
	dir := t.TempDir()
	log, err := eventlog.Open(dir + "/events.jsonl")
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer func() { _ = log.Close() }()

	for _, e := range []domain.Event{
		{ID: "d1", Type: domain.EventDeposited, Amount: "10"},
		{ID: "w1", Type: domain.EventWithdrawn, Amount: "4"},
		{ID: "d2", Type: domain.EventDeposited, Amount: "1"},
	} {
		if err := log.Append(e); err != nil {
			t.Fatalf("Append %s: %v", e.ID, err)
		}
	}

	cps, err := relay.OpenCheckpoints(dir + "/cp.json")
	if err != nil {
		t.Fatalf("OpenCheckpoints: %v", err)
	}
	pub := NewLogPublisher(nil)
	rel, err := relay.New[eventlog.SeqEvent](log, cps, EnvelopeMapper("svc.events"), pub, nil, relay.Options{Name: "publisher"})
	if err != nil {
		t.Fatalf("relay.New: %v", err)
	}
	if err := rel.RunToEnd(context.Background()); err != nil {
		t.Fatalf("RunToEnd: %v", err)
	}

	got := pub.Delivered()
	if len(got) != 3 {
		t.Fatalf("delivered %d messages, want 3 (the withdrawal must be among them)", len(got))
	}
	wantIDs := []string{"d1", "w1", "d2"}
	for i, id := range wantIDs {
		if got[i].ID != id {
			t.Fatalf("message %d id = %q, want %q (log order)", i, got[i].ID, id)
		}
	}
	if lag, err := rel.Lag(context.Background()); err != nil || lag != 0 {
		t.Fatalf("Lag = %d, %v; want 0, nil", lag, err)
	}

	// Restart: a fresh relay over the SAME checkpoint file republishes
	// nothing. A restart that floods downstream is the failure a
	// non-durable checkpoint produces.
	cps2, err := relay.OpenCheckpoints(dir + "/cp.json")
	if err != nil {
		t.Fatalf("reopen checkpoints: %v", err)
	}
	pub2 := NewLogPublisher(nil)
	rel2, err := relay.New[eventlog.SeqEvent](log, cps2, EnvelopeMapper("svc.events"), pub2, nil, relay.Options{Name: "publisher"})
	if err != nil {
		t.Fatalf("relay.New: %v", err)
	}
	if err := rel2.RunToEnd(context.Background()); err != nil {
		t.Fatalf("restarted RunToEnd: %v", err)
	}
	if n := len(pub2.Delivered()); n != 0 {
		t.Fatalf("restart republished %d messages, want 0", n)
	}

	// A new event after the restart is picked up from the stored position.
	if err := log.Append(domain.Event{ID: "d3", Type: domain.EventDeposited, Amount: "2"}); err != nil {
		t.Fatalf("Append d3: %v", err)
	}
	if err := rel2.RunToEnd(context.Background()); err != nil {
		t.Fatalf("post-restart RunToEnd: %v", err)
	}
	if d := pub2.Delivered(); len(d) != 1 || d[0].ID != "d3" {
		t.Fatalf("after restart delivered %+v, want only d3", d)
	}
}

// provenance: derived
// verifies: a publisher outage DELAYS delivery and never loses it -- the
// events published after recovery are exactly the ones that failed, with
// their original IDs
func TestEndToEnd_PublisherOutageDelaysButNeverLoses(t *testing.T) {
	dir := t.TempDir()
	log, err := eventlog.Open(dir + "/events.jsonl")
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer func() { _ = log.Close() }()
	for i := 0; i < 5; i++ {
		if err := log.Append(domain.Event{ID: "d" + strconv.Itoa(i), Type: domain.EventDeposited, Amount: "1"}); err != nil {
			t.Fatalf("Append: %v", err)
		}
	}
	cps, err := relay.OpenCheckpoints(dir + "/cp.json")
	if err != nil {
		t.Fatalf("OpenCheckpoints: %v", err)
	}
	pub := NewLogPublisher(nil)
	pub.FailUntil = 2 // every message fails once, then succeeds
	rel, err := relay.New[eventlog.SeqEvent](log, cps, EnvelopeMapper("svc.events"), pub, nil, relay.Options{Name: "publisher"})
	if err != nil {
		t.Fatalf("relay.New: %v", err)
	}

	// Each pass fails on the first not-yet-delivered message, so five passes
	// are needed. The relay never skips; it retries the same position.
	var lastErr error
	for i := 0; i < 20 && len(pub.Delivered()) < 5; i++ {
		lastErr = rel.RunToEnd(context.Background())
	}
	if n := len(pub.Delivered()); n != 5 {
		t.Fatalf("delivered %d of 5 after retries (last error: %v)", n, lastErr)
	}
	seen := map[string]int{}
	for _, m := range pub.Delivered() {
		seen[m.ID]++
	}
	for i := 0; i < 5; i++ {
		id := "d" + strconv.Itoa(i)
		if seen[id] != 1 {
			t.Fatalf("message %s delivered %d times, want exactly 1", id, seen[id])
		}
		if pub.AttemptsFor(id) < 2 {
			t.Fatalf("message %s was attempted %d times, want >= 2 (it must have been RETRIED, "+
				"not delivered on a lucky first pass)", id, pub.AttemptsFor(id))
		}
	}
}
