package observability

import (
	"context"
	"fmt"
	"log/slog"
	"net"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.43.0"
	oteltrace "go.opentelemetry.io/otel/trace"
)

// Tracing modes, mirroring config.Config.Tracing (env TRACING). The names
// are re-declared in internal/platform/config rather than imported from
// here, for the same reason LogExportOff/LogExportOTLP are: config is a leaf
// package every layer may read, and it must not pull an OTel dependency in
// behind it.
const (
	// TracingOff wires observability.NewNoop(): spans are constructed and
	// discarded. The scaffold's default.
	TracingOff = "off"
	// TracingLog wires NewLog: one structured slog line per span, through
	// the process logger, with no connection to any collector.
	TracingLog = "log"
	// TracingOTLP wires the OTLP/HTTP exporter below, shipping spans to
	// TracerOptions.Endpoint.
	//
	// THIS MODE IS WHY THE FILE EXISTS. Before it, this scaffold stamped
	// every log line with a trace_id (logging.go's traceHandler) and shipped
	// spans NOWHERE -- the id pointed at a trace no backend had ever been
	// told about. A correlation key that can never resolve is worse than no
	// correlation at all: an absent trace_id says "outside a span", while a
	// present one that 404s in the backend says "your query is wrong", and
	// people believe it.
	TracingOTLP = "otlp"
)

// TracerOptions is everything NewTracer needs, in the shape LogOptions
// already established for the logging half: every field is supplied by the
// composition root from validated config, so this package reads no
// environment of its own and a test can construct any combination without
// mutating process state.
type TracerOptions struct {
	// Mode is the validated config.Config.Tracing value: TracingOff,
	// TracingLog or TracingOTLP. config.ParseTracing has already rejected
	// anything else as a boot error, so an unrecognized value here falls
	// back to TracingOff rather than panicking -- a tracing default must
	// never be able to crash a boot.
	Mode string
	// Endpoint is the OTLP/HTTP receiver as host:port with NO scheme (e.g.
	// "tempo:4318"). Required for TracingOTLP, ignored otherwise.
	//
	// NOTE THE ASYMMETRY WITH THE LOG LANE, because it is a real trap and
	// this repo carries both halves: the OTLP LOGS exporter reads
	// OTEL_EXPORTER_OTLP_ENDPOINT itself and wants a full URL, while
	// otlptracehttp.WithEndpoint wants a bare host:port and builds the URL
	// around it. Handing this field "http://tempo:4318" makes the WHOLE
	// STRING the hostname. validateTraceEndpoint refuses it by name.
	Endpoint string
	// ServiceName and ServiceVersion identify this process in the exported
	// resource, and ServiceName doubles as the instrumentation scope name --
	// the same two fields, meaning the same two things, as LogOptions.
	ServiceName    string
	ServiceVersion string
	// Logger receives the one-line boot statement ("exporting traces over
	// OTLP/HTTP, here"). Never nil-checked by callers; NewTracer falls back
	// to slog.Default().
	Logger *slog.Logger
	// ExportFailures receives OTLP EXPORT failures, and it is a separate
	// logger from Logger for a reason that was measured, not imagined.
	//
	// `otel.SetErrorHandler` is PROCESS-GLOBAL and shared by every OTel
	// signal: go.opentelemetry.io/otel/sdk/log routes its own export
	// failures through it too. So if this handler writes through the process
	// logger while LOG_EXPORT=otlp is fanning that logger onto an OTLP lane,
	// a collector outage becomes SELF-SUSTAINING -- the WARN describing the
	// failed export is itself a log record, which is batched, which fails,
	// which emits another WARN. Measured on this scaffold with a log
	// collector returning 500 and ONE real log line emitted: 19 export
	// attempts and 19 WARN lines in 20 seconds, flat and non-decaying, with
	// no traces exported at all in that run.
	//
	// So this must be a logger that CANNOT itself export. NewTracer defaults
	// it to NewBootstrapLogger(os.Stderr) -- JSON, structured, and pointed at
	// the one lane that has no collector behind it. The trade is stated
	// plainly: a deployment whose logs only reach it through the collector
	// will not see these lines in the collector. That is the correct way
	// round, because the collector being unreachable is exactly what they
	// are about.
	ExportFailures *slog.Logger
}

// NewTracer builds the Tracer selected by opts.Mode and returns it with the
// shutdown function the composition root must defer.
//
// This is the composition-root helper cmd/<SERVICE> calls once at boot. It
// replaced a `New(mode, logger) Tracer` that could not have grown an
// exporting mode without changing shape anyway: an exporter owns a
// background batcher and a socket, so it needs a context to build under, a
// flush on the way out, and the ability to REFUSE a boot. Keeping the old
// signature beside this one would have left a second constructor that
// silently cannot export -- the kind of choice a caller makes once, wrongly,
// and never revisits.
//
// # What can fail here, and what deliberately cannot
//
// TracingOff and TracingLog own no resources: the shutdown is a no-op and
// the error is always nil. Only TracingOTLP can fail, and only on
// CONFIGURATION: an empty endpoint, or one that is not a host:port. It never
// fails on an UNREACHABLE endpoint, because it never dials one -- see
// buildOTLP.
//
// The distinction is the whole safety argument. A trace backend that is down
// at boot, or dies at 03:00, must not be able to take this service with it;
// a trace backend that was never configured correctly must not be able to
// hide behind that same tolerance. So syntax fails closed at boot, and
// reachability degrades to a WARN. What remains uncovered by either -- an
// endpoint with the right SHAPE pointing at the wrong host -- is visible
// only in the backend, which is why the deployment check is "query one
// trace back", not "the pod started".
func NewTracer(ctx context.Context, opts TracerOptions) (Tracer, func(context.Context) error, error) {
	logger := opts.Logger
	if logger == nil {
		logger = slog.Default()
	}
	if opts.ExportFailures == nil {
		opts.ExportFailures = NewBootstrapLogger(os.Stderr)
	}

	// Installed for EVERY mode, including "off", and BEFORE the switch so no
	// return path can skip it.
	//
	// The propagator is what lets a trace cross a process boundary at all;
	// leaving it to the composition root is how it came to be missing
	// entirely (see propagation.go: 3132 spans, 3132 traces). Installing it
	// under "off" costs nothing -- the noop tracer produces no span context
	// to inject -- and it removes a mode-dependent difference in behaviour
	// that nobody would think to test: a service running TRACING=log with the
	// propagator installed only on some other branch injects nothing, with no
	// error and no clue. The OTLP branch makes that failure mode WORSE rather
	// than new -- it is the mode whose spans reach a backend, so it is the
	// mode where "one trace per span" is visible to everyone.
	InstallPropagation()

	switch opts.Mode {
	case TracingOTLP:
		return buildOTLP(ctx, opts, logger)
	case TracingLog:
		return NewLog(logger), noopShutdown, nil
	default:
		return NewNoop(), noopShutdown, nil
	}
}

// buildOTLP wires the OTLP/HTTP exporter behind a batching processor.
//
// THE TRACE BACKEND BEING DOWN MUST NEVER TAKE THIS SERVICE DOWN, AND MUST
// NEVER BLOCK A COMMAND. Three things make that true, and all three are load
// bearing:
//
//  1. otlptracehttp.New does not dial. It builds a client; the first network
//     contact happens on the first export, on the processor's own goroutine.
//     So a collector that is missing at boot cannot fail this constructor,
//     and one that dies later cannot fail anything on the request path.
//  2. The processor is a BATCH processor, never a simple/synchronous one. It
//     hands spans to a bounded in-memory queue and returns immediately.
//     `Span.End()` -- which is what runs inside a deferred command close --
//     is a queue append, not an I/O call. When the queue is full the SDK
//     DROPS spans; losing telemetry while continuing to serve is the correct
//     trade, and the dropped count surfaces through the error handler below.
//  3. A global error handler routes every export failure to a WARN log.
//     Without it the SDK writes to stderr through its default handler, so
//     the one signal that traces are being lost is the one line the JSON
//     lane cannot parse.
//
// HTTP rather than gRPC on purpose: it is the lighter dependency (no gRPC
// client stack behind the request path), it is trivially debuggable with
// curl against the same port, and every collector that speaks OTLP speaks
// both.
func buildOTLP(ctx context.Context, opts TracerOptions, logger *slog.Logger) (Tracer, func(context.Context) error, error) {
	if opts.Endpoint == "" {
		return nil, nil, fmt.Errorf("observability: TRACING=%s requires an endpoint (TRACING_ENDPOINT, host:port)", TracingOTLP)
	}
	if err := validateTraceEndpoint(opts.Endpoint); err != nil {
		return nil, nil, err
	}

	exporter, err := otlptracehttp.New(ctx,
		otlptracehttp.WithEndpoint(opts.Endpoint),
		// WithInsecure is the scaffold's default because the scaffold's
		// deployment shape is a same-network hop to a sidecar-style
		// collector, which is not TLS-terminated. IT IS AN ASSUMPTION, not a
		// conclusion: a deployment whose collector sits across a trust
		// boundary is shipping span names, attributes and timings in the
		// clear. Changing it is a one-line edit here; NOTICING that it needs
		// changing is the hard part, which is why the obligation is written
		// down in registries/contract-debt.yaml's header rather than left to
		// a reader of this file.
		otlptracehttp.WithInsecure(),
		// Bounds ONE export attempt, on the batcher's goroutine. It is not a
		// budget anything on the request path waits out.
		otlptracehttp.WithTimeout(5*time.Second),
	)
	if err != nil {
		return nil, nil, fmt.Errorf("observability: otlp trace exporter: %w", err)
	}

	// resource.NewWithAttributes, not resource.Merge(resource.Default(), ...),
	// matching NewOTLPLane in logging.go so the two signals describe this
	// process identically. Merge additionally REFUSES to combine resources
	// carrying different schema URLs, which turns a semconv version drift
	// into a failed BOOT rather than a compile error -- a sharp edge worth
	// not having twice in one package.
	res := resource.NewWithAttributes(
		semconv.SchemaURL,
		semconv.ServiceName(opts.ServiceName),
		semconv.ServiceVersion(opts.ServiceVersion),
	)

	provider := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(exporter),
		sdktrace.WithResource(res),
		// THE SAMPLER IS DECLARED, NOT INHERITED. Omitting this option does
		// not mean "no sampler": the SDK then reads OTEL_TRACES_SAMPLER and
		// OTEL_TRACES_SAMPLER_ARG from the environment, so an env var this
		// repo never validates and never surfaces on /healthz could silently
		// take a service to zero traces -- the same silent-downgrade shape
		// TRACING_ENDPOINT is validated to prevent, arriving through the back
		// door. Naming the sampler here makes those variables inert.
		//
		// ParentBased(AlwaysSample) is the honest default for a scaffold: it
		// records everything this process starts, and it RESPECTS an upstream
		// decision, so a caller that sampled a request out is not overruled
		// here -- which also means a durable traceparent restored by
		// ContextWithTraceParent with sampled=0 stays unsampled, as the W3C
		// contract requires.
		//
		// A service with real volume owes a real sampling knob: a validated
		// config field, surfaced on config.Identity, next to TRACING_ENDPOINT.
		// Reaching for OTEL_TRACES_SAMPLER instead will do nothing.
		sdktrace.WithSampler(sdktrace.ParentBased(sdktrace.AlwaysSample())),
	)

	// NOTE, deliberately NOT otel.SetTracerProvider(provider). This package
	// hands the Tracer back through its own port and the composition root
	// injects it; nothing here reads the OTel global. The consequence is
	// worth stating because it is invisible: an instrumentation library added
	// later (otelhttp, otelgrpc) resolves the global TracerProvider, which is
	// still the no-op, so it would PROPAGATE correctly (InstallPropagation is
	// global) and emit nothing. The first such library this service adopts
	// must either be handed this provider explicitly -- every one of them
	// takes a WithTracerProvider option -- or this line has to be reconsidered
	// as a whole, which is a decision about the port, not a one-liner.

	// THE HANDLER IS GLOBAL AND SO IS ITS AUDIENCE. It is installed here
	// because this is the only place that builds an OTLP exporter, but
	// otel.SetErrorHandler is process-wide and the OTel LOG sdk reports
	// through it as well -- so the message must not name a signal it cannot
	// identify. It used to read "trace export failed", and with LOG_EXPORT=otlp
	// that made every log-collector failure page the wrong subsystem, while
	// the `error` field beside it said /v1/logs.
	failures := opts.ExportFailures
	otel.SetErrorHandler(otel.ErrorHandlerFunc(func(err error) {
		// COUNTED, not only logged. A WARN is what an operator reads AFTER
		// they already suspect telemetry is missing; a series is what tells
		// them without being asked, and what an alert rule can fire on. The
		// counter is process-global for the same reason the handler is:
		// otel.SetErrorHandler has no scope, so there is exactly one of these
		// per process no matter how many providers are built.
		otlpExportFailures.Add(1)
		// context.WithoutCancel(ctx), not ctx. This handler fires from the
		// batch processor's OWN goroutine, long after buildOTLP returned, and
		// ctx here is the BOOT context -- which cmd/<SERVICE> derives from
		// signal.NotifyContext, so it is cancelled by the very SIGTERM whose
		// final flush failures an operator most wants to read. Passing it
		// through would mute every export-failure warning from the moment
		// shutdown begins. Stripping the cancellation keeps the values
		// (there is no span at boot, but a future caller may attach one)
		// without inheriting a lifetime that has nothing to do with this
		// callback's.
		failures.WarnContext(context.WithoutCancel(ctx),
			"observability: OTLP export failed (service unaffected)", "error", err)
	}))

	logger.InfoContext(ctx, "observability: exporting traces over OTLP/HTTP",
		"endpoint", opts.Endpoint, "service", opts.ServiceName)

	tracer := &otlpTracer{tracer: provider.Tracer(opts.ServiceName)}
	shutdown := func(ctx context.Context) error {
		// Flush what is queued, then release. A failure here loses the last
		// batch and nothing else -- it is reported, never fatal.
		return provider.Shutdown(ctx)
	}
	return tracer, shutdown, nil
}

// validateTraceEndpoint rejects an endpoint that is not a usable host:port.
//
// IT EXISTS BECAUSE THE SDK DOES NOT DO IT. Measured against otlptracehttp
// v1.45.0, every one of these built an exporter with err == nil:
//
//	"://///bogus"
//	"not a url at all with spaces"
//	"\x7f"                          (a raw control byte)
//	"http://tempo:4318"             (the whole string becomes the HOST)
//
// TestNewTracer_OTLPFailsClosedOnEndpointsTheSDKAccepts asserts both halves
// -- that the raw SDK accepts them and that NewTracer refuses them -- so the
// day the SDK starts validating, the test says so instead of quietly
// becoming a tautology.
//
// This is the trace-side counterpart of a defect logging.go documents but
// does NOT close: otlploghttp reads OTEL_EXPORTER_OTLP_ENDPOINT itself and
// falls back to localhost:4318 on an unparseable value, and closing that
// properly means reimplementing the OTLP env precedence rules (see the KNOWN
// GAP comment in NewLogger). The trace side has no such excuse -- the
// endpoint arrives as a plain config field this package owns -- so it fails
// closed here.
//
// Why refuse at all, when a bad endpoint "only" costs telemetry: the failure
// is silent by construction. Nothing dials at boot, every export failure is
// a WARN, and shutdown() returns nil even when 100% of exports failed. A
// process reported healthy while shipping spans into a nonsense address is
// an operational lie, and it is one nobody discovers until they need the
// trace.
//
// What this canNOT catch, said plainly: an endpoint with the right SHAPE and
// the wrong host. "tempo:4318" when the collector is "tempo-gateway:4318"
// passes every check here. That half is only visible in the backend.
func validateTraceEndpoint(endpoint string) error {
	// Checked BEFORE the "://" case so the more specific message still wins
	// for a full URL, and checked at all because "://" alone did not close
	// the hole it was written for. Measured against a live collector:
	// "//127.0.0.1:PORT" passed the old guard, built an exporter, returned
	// nil from shutdown(), and delivered ZERO spans -- which is precisely
	// "the whole string became the hostname", the outcome the URL message
	// below describes. A host:port has no slash and no userinfo; both
	// characters mean the caller is thinking in URLs.
	if !strings.Contains(endpoint, "://") && strings.ContainsAny(endpoint, "/@") {
		return fmt.Errorf(
			"observability: OTLP trace endpoint %q must be host:port with no path, slash or "+
				"userinfo (e.g. tempo:4318)", endpoint)
	}
	if strings.Contains(endpoint, "://") {
		return fmt.Errorf(
			"observability: OTLP trace endpoint %q must be host:port with NO scheme "+
				"(e.g. tempo:4318); the scheme is added by the exporter, so a URL here "+
				"is parsed as the hostname. Note this is the OPPOSITE of the OTLP LOGS "+
				"endpoint, which wants a full URL including the path", endpoint)
	}
	host, port, err := net.SplitHostPort(endpoint)
	if err != nil {
		return fmt.Errorf(
			"observability: OTLP trace endpoint %q is not host:port (e.g. tempo:4318): %w",
			endpoint, err)
	}
	if host == "" {
		return fmt.Errorf("observability: OTLP trace endpoint %q has no host", endpoint)
	}
	// Control characters and spaces, checked explicitly because SplitHostPort
	// does not care: "\x7f:4318" splits perfectly happily. A byte like that
	// reaches the endpoint from a mangled env var or a stray shell quote,
	// never from a human who meant it.
	if strings.IndexFunc(host, func(r rune) bool { return r <= ' ' || r == 0x7f }) >= 0 {
		return fmt.Errorf(
			"observability: OTLP trace endpoint %q contains a space or control character in its host",
			endpoint)
	}
	// Digits only, checked before Atoi because Atoi ACCEPTS a sign:
	// strconv.Atoi("+4318") is 4318, nil, so "tempo:+4318" would pass every
	// range check and then fail to dial.
	if port == "" || strings.IndexFunc(port, func(r rune) bool { return r < '0' || r > '9' }) >= 0 {
		return fmt.Errorf(
			"observability: OTLP trace endpoint %q has a non-numeric port (want 1-65535, got %q)",
			endpoint, port)
	}
	number, err := strconv.Atoi(port)
	if err != nil || number < 1 || number > 65535 {
		return fmt.Errorf(
			"observability: OTLP trace endpoint %q has no usable port (want 1-65535, got %q)",
			endpoint, port)
	}
	return nil
}

// otlpExportFailures counts every OTLP export failure the process observes,
// across ALL signals -- traces and, when LOG_EXPORT=otlp, logs too, because
// the OTel error handler they share does not distinguish them.
//
// Exposed as a FUNCTION rather than a variable so the metrics surface can be
// handed `observability.OTLPExportFailures` without importing anything about
// how it is counted, and so nothing outside this package can reset it.
var otlpExportFailures atomic.Int64

// OTLPExportFailures reports how many OTLP exports have failed since boot.
//
// The composition root passes this to the health server, which publishes it
// as svc_otlp_export_failures_total. Without that hop the only evidence that
// telemetry is being lost is a log line -- and a log line is a poor signal
// for "logs may not be reaching you", which is one of the two cases this
// counts.
//
// It is monotonic and never reset: a counter that goes down is a counter
// every Prometheus rate() misreads as a restart.
func OTLPExportFailures() int64 { return otlpExportFailures.Load() }

// otlpTracer adapts this package's dependency-free Tracer port onto an OTel
// tracer. It exists so that the port's shape -- and therefore every call
// site in the module -- is unchanged by the choice of backend.
type otlpTracer struct {
	tracer oteltrace.Tracer
}

func (t *otlpTracer) StartSpan(ctx context.Context, name string, attrs map[string]string) (context.Context, Span) {
	// Belt and braces, and labelled as such: otel/trace already returns the
	// noop span for a nil context, so removing this line leaves
	// TestOTLPTracer_NilContextStillRecordsASpan green (measured). It stays
	// because that behaviour is a DEPENDENCY's internal, and the blast radius
	// if it ever changes is a panic raised from inside a deferred End() --
	// while describing the failure it was supposed to report.
	if ctx == nil {
		ctx = context.Background()
	}
	// Sorted for a deterministic attribute order, matching what the log
	// tracer already guarantees. Two backends that disagree about ordering
	// make two recordings of the same operation gratuitously hard to diff.
	keys := make([]string, 0, len(attrs))
	for k := range attrs {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	kv := make([]attribute.KeyValue, 0, len(keys))
	for _, k := range keys {
		// snake_case keys, like every other attribute, log key and metric
		// label in this repo -- see the naming note on traceHandler in
		// logging.go. Nothing rewrites them here; the convention is upheld
		// at the call sites (observability/spans.yaml is the manifest).
		kv = append(kv, attribute.String(k, attrs[k]))
	}

	// t.tracer.Start makes the new span a CHILD of whatever span context ctx
	// already carries -- including a REMOTE parent restored by
	// ContextWithTraceParent from a durable record -- and a fresh root only
	// when ctx carries nothing. Same rule as logTracer.StartSpan; it is what
	// makes a trace span a process boundary and a restart.
	ctx, span := t.tracer.Start(ctx, name, oteltrace.WithAttributes(kv...))
	return ctx, &otlpSpan{span: span}
}

type otlpSpan struct {
	span oteltrace.Span
}

// RecordError marks the span as failed and attaches err.
//
// A nil err is a no-op, matching the Span port's documented contract and
// both other adapters (logSpan, recordingSpan). This is not defensive
// nicety: the composition root's adapter calls span.RecordError(err)
// unconditionally in a deferred close (cmd/<SERVICE>'s adaptTracer), so
// every SUCCESSFUL command reaches this method with a nil error. Without the
// guard, every span in the service would be marked Error and the backend's
// error filter -- the only way anyone finds a failure -- would select
// everything, which is the same as selecting nothing.
func (s *otlpSpan) RecordError(err error) {
	if err == nil {
		return
	}
	s.span.RecordError(err)
	// RecordError alone only attaches an exception EVENT; the span still
	// reads as OK ("Unset") in every backend's UI and in every error filter.
	// Setting the status is what makes a failed command FINDABLE rather than
	// merely annotated, and finding it is the only reason the annotation was
	// worth recording.
	s.span.SetStatus(codes.Error, err.Error())
}

func (s *otlpSpan) End() { s.span.End() }
