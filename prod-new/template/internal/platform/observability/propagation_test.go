package observability

import (
	"context"
	"log/slog"
	"net/http"
	"testing"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/propagation"
	oteltrace "go.opentelemetry.io/otel/trace"
)

// spanCtx returns a context carrying a real, valid span context, the way the
// log tracer produces one on a live request path.
func spanCtx(t *testing.T) context.Context {
	t.Helper()
	ctx, span := NewLog(slog.New(slog.NewJSONHandler(discard{}, nil))).
		StartSpan(context.Background(), "svc.deposit", nil)
	span.End()
	// Guards every assertion below against being vacuously true: if the
	// tracer stopped deriving a span context, injection would write nothing
	// and every "did it survive the boundary" check would compare two
	// absences.
	if !oteltrace.SpanContextFromContext(ctx).IsValid() {
		t.Fatal("the log tracer produced no valid span context")
	}
	return ctx
}

type discard struct{}

func (discard) Write(p []byte) (int, error) { return len(p), nil }

// provenance: regression
// verifies: observability -- trace context SURVIVES an HTTP boundary, so a
// span started on the far side is a child of the near side's rather than a new
// root.
//
// This is the property whose absence produced 3132 spans in 3132 traces in the
// service this template was extracted from, with every individual mechanism
// green. Asserted as a ROUND TRIP through Extract rather than by reading the
// header's text: matching the text only re-types the W3C format, whereas a
// round trip asserts what the receiving process will actually do.
func TestTraceContext_SurvivesAnHTTPBoundary(t *testing.T) {
	callerCtx := spanCtx(t)
	want := oteltrace.SpanContextFromContext(callerCtx)

	header := http.Header{}
	InjectTraceContext(callerCtx, header)
	if header.Get("Traceparent") == "" {
		t.Fatal("nothing was injected -- the request crosses the boundary carrying no trace context at all")
	}

	// The far side: a fresh process, nothing but the header.
	serverCtx := ExtractTraceContext(context.Background(), header)
	got := oteltrace.SpanContextFromContext(serverCtx)
	if got.TraceID() != want.TraceID() {
		t.Fatalf("trace id across the boundary = %s, want %s", got.TraceID(), want.TraceID())
	}
	if got.SpanID() != want.SpanID() {
		t.Fatalf("parent span id across the boundary = %s, want %s", got.SpanID(), want.SpanID())
	}
	if !got.IsRemote() {
		t.Error("the extracted span context is not marked remote -- a parent from another process is remote by construction")
	}

	// And the span the far side starts is genuinely in the SAME trace.
	childCtx, span := NewLog(slog.New(slog.NewJSONHandler(discard{}, nil))).
		StartSpan(serverCtx, "svc.downstream", nil)
	span.End()
	child := oteltrace.SpanContextFromContext(childCtx)
	if child.TraceID() != want.TraceID() {
		t.Fatalf("the far side's span is in trace %s, want %s -- it is a new root, "+
			"so the backend stores one trace per span", child.TraceID(), want.TraceID())
	}
	if child.SpanID() == want.SpanID() {
		t.Fatal("the far side's span reused the parent's span id")
	}
}

// provenance: derived
// verifies: injection is UNCONDITIONALLY SAFE on a request path -- a context
// with no span writes no header and cannot fail.
func TestInject_WithoutASpanWritesNothing(t *testing.T) {
	header := http.Header{}
	InjectTraceContext(context.Background(), header)
	if len(header) != 0 {
		t.Fatalf("injected %v from a context with no span", header)
	}
	metadata := map[string]string{}
	InjectMetadata(context.Background(), metadata)
	if len(metadata) != 0 {
		t.Fatalf("injected %v into metadata from a context with no span", metadata)
	}
	if got := TraceParentFromContext(context.Background()); got != "" {
		t.Fatalf("TraceParentFromContext(no span) = %q, want empty", got)
	}
}

// provenance: derived
// verifies: extraction NEVER fails an inbound request -- a caller with no
// traceparent, or a malformed one, starts a new trace instead of an error.
func TestExtract_WithoutAUsableHeaderLeavesTheContextAlone(t *testing.T) {
	type key struct{}
	ctx := context.WithValue(context.Background(), key{}, "kept")

	for name, header := range map[string]http.Header{
		"absent":    {},
		"malformed": {"Traceparent": {"not-a-traceparent"}},
	} {
		got := ExtractTraceContext(ctx, header)
		if got.Value(key{}) != "kept" {
			t.Fatalf("%s: extraction discarded the caller's context", name)
		}
		if oteltrace.SpanContextFromContext(got).IsValid() {
			t.Fatalf("%s: extraction invented a valid span context", name)
		}
	}

	if got := ContextWithTraceParent(ctx, ""); got.Value(key{}) != "kept" {
		t.Fatal(`ContextWithTraceParent(ctx, "") did not return ctx unchanged`)
	}
}

// provenance: regression
// verifies: a MESSAGE carrier writes the W3C key VERBATIM ("traceparent"),
// not the canonicalized "Traceparent" that net/http uses.
//
// Not pedantry, and not theoretical. propagation.HeaderCarrier runs every key
// through textproto.CanonicalMIMEHeaderKey; nats.Header.Get is documented
// case-sensitive and indexes the map with the key verbatim. Injecting with the
// HTTP carrier onto a message therefore produces a header that is present,
// correct, and found by nobody -- invisible over HTTP, where the protocol is
// case-insensitive and Go canonicalizes on both sides.
func TestMessageCarriers_UseTheCaseSensitiveW3CKey(t *testing.T) {
	ctx := spanCtx(t)
	want := oteltrace.SpanContextFromContext(ctx)

	metadata := map[string]string{}
	InjectMetadata(ctx, metadata)
	if _, ok := metadata[TraceParentHeader]; !ok {
		t.Fatalf("metadata = %v, want a lowercase %q key -- a consumer indexing verbatim finds nothing",
			metadata, TraceParentHeader)
	}
	if _, ok := metadata["Traceparent"]; ok {
		t.Fatalf("metadata carries the CANONICALIZED key too: %v", metadata)
	}

	headers := map[string][]string{}
	InjectMessageHeaders(ctx, headers)
	if _, ok := headers[TraceParentHeader]; !ok {
		t.Fatalf("message headers = %v, want a lowercase %q key", headers, TraceParentHeader)
	}
	if _, ok := headers["Traceparent"]; ok {
		t.Fatalf("message headers carry the CANONICALIZED key too: %v", headers)
	}

	// Round trip, because only the extractor proves the header is CONSUMABLE.
	if got := oteltrace.SpanContextFromContext(ExtractMetadata(context.Background(), metadata)); got.TraceID() != want.TraceID() {
		t.Fatalf("ExtractMetadata round trip trace id = %s, want %s", got.TraceID(), want.TraceID())
	}
	if got := oteltrace.SpanContextFromContext(ExtractMessageHeaders(context.Background(), headers)); got.TraceID() != want.TraceID() {
		t.Fatalf("ExtractMessageHeaders round trip trace id = %s, want %s", got.TraceID(), want.TraceID())
	}
}

// provenance: regression
// verifies: injection is ADDITIVE -- every header/metadata entry that was
// already there survives byte-identical.
//
// A carrier that Set()s over a map is one typo away from replacing it, and the
// entries it would replace here are the envelope a consumer deduplicates on.
// Losing them to add telemetry would be a spectacularly bad trade, and it
// would surface as a data bug, not as a tracing bug.
func TestInjection_LeavesExistingEntriesByteIdentical(t *testing.T) {
	ctx := spanCtx(t)

	metadata := map[string]string{"es_event_id": "e1", "es_schema": "1"}
	InjectMetadata(ctx, metadata)
	if metadata["es_event_id"] != "e1" || metadata["es_schema"] != "1" {
		t.Fatalf("injection disturbed the existing metadata: %v", metadata)
	}

	header := http.Header{"Idempotency-Key": {"k1"}, "Content-Type": {"application/json"}}
	InjectTraceContext(ctx, header)
	if header.Get("Idempotency-Key") != "k1" || header.Get("Content-Type") != "application/json" {
		t.Fatalf("injection disturbed the existing headers: %v", header)
	}
}

// provenance: regression
// verifies: the DURABLE gap -- a traceparent captured as text re-parents work
// that happens later, in another goroutine or another process.
//
// This is the pair the event log uses: TraceParentFromContext at commit,
// ContextWithTraceParent at publish. Nothing else in a context survives a
// restart, so without these two the publish of a committed fact is always a
// fresh root.
func TestTraceParent_RoundTripsThroughText(t *testing.T) {
	ctx := spanCtx(t)
	want := oteltrace.SpanContextFromContext(ctx)

	text := TraceParentFromContext(ctx)
	if text == "" {
		t.Fatal("captured no traceparent from a context that carries a span")
	}

	// A different process: nothing but the string.
	restored := oteltrace.SpanContextFromContext(ContextWithTraceParent(context.Background(), text))
	if restored.TraceID() != want.TraceID() || restored.SpanID() != want.SpanID() {
		t.Fatalf("restored %s/%s, want %s/%s", restored.TraceID(), restored.SpanID(), want.TraceID(), want.SpanID())
	}
	if !restored.IsRemote() {
		t.Error("a parent restored from durable text is not marked remote -- it ended elsewhere, possibly in another process")
	}
	if got := ContextWithTraceParent(context.Background(), "garbage"); oteltrace.SpanContextFromContext(got).IsValid() {
		t.Error("a malformed stored traceparent produced a valid span context")
	}
}

// provenance: regression
// verifies: New installs the propagator for EVERY tracing mode, before the
// mode switch.
//
// The mode-dependent version of this bug is the nastiest shape it takes: a
// deployment running the OTLP backend propagates and a deployment running the
// log backend does not, so the gap appears only in the environments nobody
// instruments first. The global's DEFAULT is a no-op propagator that silently
// drops everything, which is what makes the difference invisible.
//
// The test asserts through `otel.GetTextMapPropagator()` -- the global -- and
// not through this package's own Inject, precisely because this package's
// Inject uses its own propagator and would pass even if InstallPropagation
// were deleted outright.
func TestNew_InstallsThePropagatorForEveryMode(t *testing.T) {
	for _, mode := range []string{"off", "", "log", "bogus"} {
		t.Run("mode="+mode, func(t *testing.T) {
			// Start from the SDK's default: a no-op propagator that drops
			// everything. Anything green from here is green because New
			// installed something.
			otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator())

			tr := New(mode, slog.New(slog.NewJSONHandler(discard{}, nil)))
			if tr == nil {
				t.Fatal("New returned no tracer")
			}

			ctx := spanCtx(t)
			header := http.Header{}
			otel.GetTextMapPropagator().Inject(ctx, propagation.HeaderCarrier(header))
			if header.Get("Traceparent") == "" {
				t.Fatalf("TRACING=%q leaves the PROCESS-WIDE propagator a no-op: every instrumentation "+
					"library that consults the global (otelhttp, otelgrpc, anything added later) "+
					"silently propagates nothing", mode)
			}
		})
	}
	// Leave the process as a real boot does.
	InstallPropagation()
}

// provenance: derived
// verifies: both message carriers satisfy propagation.TextMapCarrier
// COMPLETELY -- Get, Set and Keys.
//
// Keys has no caller in the W3C trace-context path (TraceContext and Baggage
// both read by name), which is exactly why it is asserted here: an
// implementation nothing exercises is one that gets written wrong and stays
// wrong until the first propagator that enumerates -- and that propagator
// arrives as a dependency upgrade, not as a code change anybody reviewed.
func TestCarriers_ImplementTheFullTextMapCarrierContract(t *testing.T) {
	carriers := map[string]propagation.TextMapCarrier{
		"exactKeyCarrier": exactKeyCarrier{},
		"metadataCarrier": metadataCarrier{},
	}
	for name, carrier := range carriers {
		t.Run(name, func(t *testing.T) {
			if got := carrier.Get(TraceParentHeader); got != "" {
				t.Fatalf("Get on an empty carrier = %q, want empty", got)
			}
			if got := carrier.Keys(); len(got) != 0 {
				t.Fatalf("Keys on an empty carrier = %v, want none", got)
			}
			carrier.Set(TraceParentHeader, "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01")
			carrier.Set("baggage", "k=v")
			if got := carrier.Get(TraceParentHeader); got != "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01" {
				t.Fatalf("Get after Set = %q", got)
			}
			keys := carrier.Keys()
			if len(keys) != 2 {
				t.Fatalf("Keys = %v, want both keys that were Set", keys)
			}
			for _, k := range keys {
				if k != TraceParentHeader && k != "baggage" {
					t.Fatalf("Keys reported %q, which was never Set", k)
				}
			}
		})
	}
}
