package observability

import (
	"context"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/propagation"
)

// This file is the half of tracing that makes a trace CROSS A BOUNDARY.
// Everything else in this package is about producing a span correctly; none
// of it makes two spans belong to the same trace.
//
// THE DEFECT THIS EXISTS FOR WAS MEASURED, NOT IMAGINED. In a service with
// the tracer wired, spans reaching the backend with full attribute fidelity,
// RecordError firing on exactly the declared condition and a green span
// contract test, the backend reported after ~15 real requests:
//
//	tempo_distributor_spans_received_total  3132
//	tempo_ingester_traces_created_total     3132
//
// One trace created per span received, process-wide -- nothing joinable to
// anything. `otel.SetTextMapPropagator` was never called anywhere, so the
// global propagator was OTel's NO-OP: a request carrying
// `traceparent: 00-111...111-222...222-01` produced HTTP 404 for trace id
// 1111... in the backend, because the header was read by nobody and the span
// was started as a fresh root.
//
// Note what none of the existing checks could see: the tracer IS wired and IS
// reachable, so every "is tracing on" probe passes. The defect is semantic,
// and the only mechanical signal is whether anything in the process injects
// or extracts at all -- which is exactly what the standard's
// `observability:trace_propagation` row measures.

// TraceParentHeader is the W3C header name, LOWERCASE, which is the form the
// specification's own examples use and the form every message-bus consumer
// looks for.
//
// It is a constant rather than a literal because the case matters and the
// case is invisible at a call site: net/http canonicalizes to "Traceparent"
// on both sides so HTTP never notices, while a message header map indexed
// verbatim (nats.Header.Get is documented case-sensitive) finds nothing at
// all. One name, spelled once.
const TraceParentHeader = "traceparent"

// tracePropagator is the W3C `traceparent`/`tracestate` propagator plus
// baggage.
//
// It is a package variable USED DIRECTLY by Inject/Extract below, rather than
// a lookup of `otel.GetTextMapPropagator()`, and that is deliberate: the
// global's default is a NO-OP propagator that silently drops everything.
// Routing this package's own injection through the global would mean a
// composition root that forgot InstallPropagation gets injection functions
// that compile, run, log nothing and propagate nothing -- the exact
// wired-but-inert failure this file exists to end. Here, calling Inject
// injects.
//
// Baggage is included because it costs one header only when something
// actually sets baggage, and its absence is discovered at the far end of a
// boundary, which is the worst place to discover it.
var tracePropagator propagation.TextMapPropagator = propagation.NewCompositeTextMapPropagator(
	propagation.TraceContext{},
	propagation.Baggage{},
)

// InstallPropagation publishes tracePropagator as the OTel process-wide
// propagator, so any instrumentation library that consults the global
// (otelhttp, otelgrpc, anything added later) agrees with the injection this
// package performs by hand.
//
// New calls it for EVERY tracing mode, before the mode switch -- see the
// comment there. A propagator installed only on the branch that builds a real
// exporter is a propagator a service running any other mode does not have.
func InstallPropagation() { otel.SetTextMapPropagator(tracePropagator) }

// InjectTraceContext writes the trace context in ctx into an HTTP header map
// (pass an http.Header directly -- it is a map[string][]string). A ctx with no
// span is a no-op: nothing is written and no error is possible, which is what
// keeps this callable unconditionally on a request path.
//
// The carrier canonicalizes keys the way net/http does ("Traceparent"), which
// is correct for HTTP and WRONG for a message bus -- see InjectMessageHeaders.
func InjectTraceContext(ctx context.Context, header map[string][]string) {
	tracePropagator.Inject(ctx, propagation.HeaderCarrier(header))
}

// ExtractTraceContext returns ctx with the remote trace context read from an
// HTTP header map attached, so a span started from the returned context is a
// CHILD of the caller's span instead of a new root. A header map carrying no
// (or a malformed) traceparent yields ctx unchanged -- an inbound request from
// an uninstrumented caller must never fail, it just starts a new trace.
//
// This scaffold's only inbound HTTP surface is health/readiness/metrics, and
// none of those handlers starts a span, so extracting there would attach a
// parent to nothing. The function is exported, exercised and documented here
// so the FIRST write handler a service adds has one obvious correct thing to
// call: `ctx := observability.ExtractTraceContext(r.Context(), r.Header)`,
// passed onward instead of `r.Context()`. Skipping that line is how every
// order in a real service became an island.
func ExtractTraceContext(ctx context.Context, header map[string][]string) context.Context {
	return tracePropagator.Extract(ctx, propagation.HeaderCarrier(header))
}

// InjectMessageHeaders is InjectTraceContext for a MESSAGE header map whose
// lookup is case-sensitive -- nats.Header is exactly that (`Get` is documented
// case-sensitive and indexes the map with the key verbatim), and it is also a
// map[string][]string, so it can be passed directly.
//
// The distinction is not pedantry. propagation.HeaderCarrier runs every key
// through textproto.CanonicalMIMEHeaderKey, so it would store "Traceparent"
// while the W3C name -- and what every message consumer asks for -- is the
// lowercase "traceparent". Over HTTP that is invisible because the protocol is
// case-insensitive and Go canonicalizes on both sides; over a message bus it
// is a header that is present, correct, and found by nobody.
func InjectMessageHeaders(ctx context.Context, header map[string][]string) {
	tracePropagator.Inject(ctx, exactKeyCarrier(header))
}

// ExtractMessageHeaders is ExtractTraceContext for the same case-sensitive
// message headers InjectMessageHeaders writes.
//
// Exported and tested even where this scaffold does not consume messages,
// because a round trip through the extractor is the only way to prove the
// injected header is actually CONSUMABLE. An injection test that asserts the
// header's text merely re-types the format.
func ExtractMessageHeaders(ctx context.Context, header map[string][]string) context.Context {
	return tracePropagator.Extract(ctx, exactKeyCarrier(header))
}

// InjectMetadata is InjectMessageHeaders for the single-valued metadata map
// this scaffold's relay carries (relay.Message.Metadata, map[string]string),
// which most brokers map to transport headers.
//
// Keys are written VERBATIM, for the same reason as InjectMessageHeaders: the
// consumer on the other side looks up "traceparent", not "Traceparent".
func InjectMetadata(ctx context.Context, metadata map[string]string) {
	tracePropagator.Inject(ctx, metadataCarrier(metadata))
}

// ExtractMetadata returns ctx with the trace context carried in metadata
// attached. This is the CONSUMER's half of InjectMetadata: whatever runs under
// the returned context belongs to the producer's trace instead of starting a
// new one.
func ExtractMetadata(ctx context.Context, metadata map[string]string) context.Context {
	return tracePropagator.Extract(ctx, metadataCarrier(metadata))
}

// TraceParentFromContext renders ctx's span context as a W3C traceparent, or
// "" when ctx carries no span.
//
// It exists because a durable record's life has two halves that happen at
// different times: the fact is COMMITTED inside a command, which runs under a
// span, and it is PUBLISHED later by the relay, which runs under the process
// context and has no span at all. Without carrying the parent across that gap
// every published event is an orphan root -- the shape that produced 3132
// traces for 3132 spans.
//
// Stored as TEXT rather than as a context because the gap is a DURABLE one:
// the record may be published by a different process, after a restart, hours
// later. A traceparent is the only part of a context that survives that, and
// it is the same string the wire carries.
func TraceParentFromContext(ctx context.Context) string {
	carrier := map[string][]string{}
	InjectMessageHeaders(ctx, carrier)
	if v := carrier[TraceParentHeader]; len(v) > 0 {
		return v[0]
	}
	return ""
}

// ContextWithTraceParent rebuilds a context carrying the producing span as the
// REMOTE parent of whatever happens next.
//
// The reconstructed span context is remote by construction, which is the
// honest description: the span that produced this record has usually already
// ended, and may have ended in a previous process. Work attributed to it is a
// child of a finished parent, which is exactly what a traceparent on the wire
// means everywhere else.
//
// An empty or malformed traceparent yields ctx unchanged rather than an error.
// A missing parent is a pre-propagation record, and refusing to publish a
// committed fact because its PROVENANCE is unknown would trade a real delivery
// for a telemetry nicety.
func ContextWithTraceParent(ctx context.Context, traceparent string) context.Context {
	if traceparent == "" {
		return ctx
	}
	return ExtractMessageHeaders(ctx, map[string][]string{
		TraceParentHeader: {traceparent},
	})
}

// exactKeyCarrier is a TextMapCarrier over a multi-valued header map that
// stores and reads keys VERBATIM, with no MIME canonicalization.
type exactKeyCarrier map[string][]string

func (c exactKeyCarrier) Get(key string) string {
	if v := c[key]; len(v) > 0 {
		return v[0]
	}
	return ""
}

func (c exactKeyCarrier) Set(key, value string) { c[key] = []string{value} }

func (c exactKeyCarrier) Keys() []string {
	keys := make([]string, 0, len(c))
	for k := range c {
		keys = append(keys, k)
	}
	return keys
}

// metadataCarrier is exactKeyCarrier for a single-valued metadata map.
type metadataCarrier map[string]string

func (c metadataCarrier) Get(key string) string { return c[key] }

func (c metadataCarrier) Set(key, value string) { c[key] = value }

func (c metadataCarrier) Keys() []string {
	keys := make([]string, 0, len(c))
	for k := range c {
		keys = append(keys, k)
	}
	return keys
}
