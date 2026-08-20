package observability

import (
	"context"
	"errors"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"
	oteltrace "go.opentelemetry.io/otel/trace"
)

// deadEndpoint is a real host:port that nothing listens on. Port 1 on
// loopback is closed on every platform this builds for, so an export attempt
// gets an immediate ECONNREFUSED and no DNS lookup.
//
// It is the FRIENDLY form of "the backend is down" and is used here only for
// tests about construction, never for the blocking claim -- see
// hungBackend, and the measurement recorded on the test that uses it.
const deadEndpoint = "127.0.0.1:1"

// hungBackend starts a listener that ACCEPTS connections and then answers
// nothing, returning its host:port.
//
// This, not a closed port, is what a trace backend being down actually looks
// like when it matters: an overloaded collector, a blackholed route, a
// sidecar mid-restart. The measurements that justify the choice are recorded
// on the test that uses it, below.
func hungBackend(t *testing.T) string {
	t.Helper()
	lis, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	var mu sync.Mutex
	var held []net.Conn
	accepting := make(chan struct{})
	go func() {
		defer close(accepting)
		for {
			conn, err := lis.Accept()
			if err != nil {
				return
			}
			// Hold the connection open, read nothing, write nothing. Keeping
			// a reference is the point: a dropped conn would be closed and
			// the client would see EOF instead of hanging.
			mu.Lock()
			held = append(held, conn)
			mu.Unlock()
		}
	}()
	t.Cleanup(func() {
		_ = lis.Close()
		<-accepting
		mu.Lock()
		for _, c := range held {
			_ = c.Close()
		}
		mu.Unlock()
	})
	return lis.Addr().String()
}

func discardLogger() *slog.Logger {
	return slog.New(slog.NewJSONHandler(discard{}, nil))
}

// restoreGlobals puts back the process-wide OTel error handler after a test
// that installs one through NewTracer.
//
// buildOTLP calls otel.SetErrorHandler, which is global and has no scope: a
// test double left installed stays reachable from SDK export goroutines that
// outlive the test that created it, so a LATER test's failures get counted by
// an EARLIER test's recorder. Restoring is cheap; debugging a count that is
// off by one in a different file is not.
func restoreGlobals(t *testing.T) {
	t.Helper()
	previous := otel.GetErrorHandler()
	t.Cleanup(func() { otel.SetErrorHandler(previous) })
}

// provenance: derived
// verifies: tracing port (mode selection) -- TRACING=otlp selects the
// exporting backend, and the exporting backend alone owns a real shutdown.
func TestNewTracer_OTLPModeSelectsTheExportingBackend(t *testing.T) {
	tr, shutdown, err := NewTracer(context.Background(), TracerOptions{
		Mode:           TracingOTLP,
		Endpoint:       deadEndpoint,
		ServiceName:    "svc",
		ServiceVersion: "test",
		Logger:         discardLogger(),
		ExportFailures: discardLogger(),
	})
	if err != nil {
		t.Fatalf("NewTracer(otlp) errored against a dead backend: %v", err)
	}
	if _, ok := tr.(*otlpTracer); !ok {
		t.Fatalf("NewTracer(otlp) returned %T, want *otlpTracer", tr)
	}
	if err := shutdown(context.Background()); err != nil {
		t.Fatalf("shutdown: %v", err)
	}
}

// provenance: derived
// verifies: fail-closed configuration -- TRACING=otlp with no endpoint is a
// boot error, not a silent downgrade to no export.
func TestNewTracer_OTLPRequiresAnEndpoint(t *testing.T) {
	tr, shutdown, err := NewTracer(context.Background(), TracerOptions{
		Mode:   TracingOTLP,
		Logger: discardLogger(),
	})
	if err == nil {
		_ = shutdown(context.Background())
		t.Fatal("TRACING=otlp with an empty endpoint built a tracer instead of refusing the boot")
	}
	if tr != nil || shutdown != nil {
		t.Fatal("a refused boot returned a non-nil tracer or shutdown")
	}
	if !strings.Contains(err.Error(), "TRACING_ENDPOINT") {
		t.Fatalf("error %q does not name the env var an operator has to set", err)
	}
}

// provenance: regression
// verifies: fail-closed configuration -- every endpoint the OTel SDK accepts
// silently is refused here.
//
// THE ASSERTION HAS TWO HALVES AND BOTH MATTER. The first drives
// otlptracehttp.New DIRECTLY and requires it to return a nil error: that is
// the measured SDK behaviour this validation exists for, and pinning it means
// the day the SDK starts validating, this test says so out loud instead of
// quietly degrading into a tautology about our own code. The second requires
// NewTracer to refuse the same input.
//
// Without the first half, deleting validateTraceEndpoint would still be
// caught -- but nobody reading the test would know WHY the function is not
// redundant with the library.
func TestNewTracer_OTLPFailsClosedOnEndpointsTheSDKAccepts(t *testing.T) {
	malformed := []struct {
		name     string
		endpoint string
	}{
		{"scheme-and-slashes", "://///bogus"},
		{"prose-with-spaces", "not a url at all with spaces"},
		{"raw-control-byte", "\x7f"},
		{"control-byte-with-port", "\x7f:4318"},
		{"full-url-becomes-the-hostname", "http://tempo:4318"},
		// MEASURED against a live collector, not reasoned about: this one
		// passed the original "://" guard, built an exporter, returned nil
		// from shutdown(), and delivered ZERO spans. It is the same
		// "the whole string became the hostname" outcome as the case above,
		// wearing a shape the first guard did not recognise.
		{"scheme-relative-url", "//tempo:4318"},
		{"host-with-path", "tempo:4318/v1/traces"},
		{"userinfo", "user@tempo:4318"},
		{"signed-port-atoi-accepts", "tempo:+4318"},
		{"no-port", "tempo"},
		{"port-zero", "tempo:0"},
		{"port-out-of-range", "tempo:70000"},
		{"port-not-a-number", "tempo:http"},
		{"no-host", ":4318"},
	}
	for _, tc := range malformed {
		t.Run(tc.name, func(t *testing.T) {
			// Half 1: the SDK itself does NOT reject this.
			exp, sdkErr := otlptracehttp.New(context.Background(),
				otlptracehttp.WithEndpoint(tc.endpoint),
				otlptracehttp.WithInsecure(),
			)
			if sdkErr != nil {
				t.Fatalf("otlptracehttp.New now REJECTS %q (%v) -- the SDK grew validation, so revisit "+
					"validateTraceEndpoint instead of leaving two disagreeing checks", tc.endpoint, sdkErr)
			}
			_ = exp.Shutdown(context.Background())

			// Half 2: we do.
			tr, shutdown, err := NewTracer(context.Background(), TracerOptions{
				Mode:           TracingOTLP,
				Endpoint:       tc.endpoint,
				Logger:         discardLogger(),
				ExportFailures: discardLogger(),
			})
			if err == nil {
				_ = shutdown(context.Background())
				t.Fatalf("NewTracer accepted the malformed endpoint %q: the boot is reported healthy "+
					"while every span goes into a nonsense address, and shutdown() returns nil either way", tc.endpoint)
			}
			if tr != nil || shutdown != nil {
				t.Fatalf("a refused boot returned a non-nil tracer/shutdown for %q", tc.endpoint)
			}
			if !strings.Contains(err.Error(), tc.endpoint) && tc.endpoint != "\x7f" && tc.endpoint != "\x7f:4318" {
				t.Fatalf("error %q does not quote the offending endpoint", err)
			}
		})
	}
}

// provenance: derived
// verifies: fail-closed configuration -- a well-formed endpoint is accepted,
// so the validation above is not simply refusing everything.
//
// The counterpart to a fail-closed test, and the half that is usually
// missing: a check that rejects all input passes every negative case and is
// worthless.
func TestValidateTraceEndpoint_AcceptsWellFormedHostPort(t *testing.T) {
	for _, ok := range []string{"tempo:4318", "127.0.0.1:14318", "collector.observability.svc.cluster.local:4318", "[::1]:4318", "host:65535", "host:1"} {
		if err := validateTraceEndpoint(ok); err != nil {
			t.Errorf("validateTraceEndpoint(%q) = %v, want nil", ok, err)
		}
	}
}

// provenance: regression
// verifies: "telemetry is never on the critical path" -- a trace backend that
// is DOWN neither fails the boot nor blocks the code that emits spans.
//
// This is the claim the whole exporting mode rests on, and it is the one that
// cannot be established by reading: `sdktrace.WithBatcher` versus
// `WithSyncer` is a one-word difference with no compile-time consequence, and
// the synchronous form puts a network round trip inside every End() -- which
// runs inside a deferred command close, on the request path.
//
// THE BACKEND HANGS RATHER THAN REFUSING, and the choice is the whole
// non-vacuity of this test. Both regimes were MEASURED here by substituting
// WithSyncer for WithBatcher:
//
//	refused port (127.0.0.1:1), syncer: 1000 spans in 80.4ms  -> STILL GREEN
//	hung listener,              syncer: did not finish in 2 MINUTES
//	hung listener,              batcher: 1000 spans in 1.28ms
//
// The first line is why this test does not use deadEndpoint: a refused
// connection costs ~80us synchronously, which slips under a 100ms bound and
// makes the assertion decoration. A hung one blocks on otlptracehttp's own
// timeout AND its retries, so the separation is four orders of magnitude and
// the bound can stay loose enough not to flake on a loaded CI runner.
//
// A hung collector is also the more common production shape: routes get
// blackholed and sidecars restart far more often than a port cleanly refuses.
func TestNewTracer_OTLPAgainstADeadBackendNeitherFailsBootNorBlocksSpans(t *testing.T) {
	tr, shutdown, err := NewTracer(context.Background(), TracerOptions{
		Mode:           TracingOTLP,
		Endpoint:       hungBackend(t),
		ServiceName:    "svc",
		ServiceVersion: "test",
		Logger:         discardLogger(),
		ExportFailures: discardLogger(),
	})
	if err != nil {
		t.Fatalf("a dead trace backend failed the BOOT: %v", err)
	}
	t.Cleanup(func() {
		// A SHORT budget on purpose: the backend never answers, so this flush
		// cannot succeed, and the test must not wait out the exporter's own
		// 5s timeout to find that out. Shutdown returning an error here is
		// the expected outcome and is not the assertion.
		ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
		defer cancel()
		_ = shutdown(ctx)
	})

	const spans = 1000
	start := time.Now()
	for i := 0; i < spans; i++ {
		_, span := tr.StartSpan(context.Background(), "svc.deposit", map[string]string{"event_type": "deposit"})
		span.End()
	}
	elapsed := time.Since(start)
	if elapsed > 100*time.Millisecond {
		t.Fatalf("%d spans against a HUNG backend took %v -- End() is doing I/O, so a collector that "+
			"stops answering stalls the request path. The processor must be a batcher, not a syncer", spans, elapsed)
	}
	t.Logf("%d spans against a hung backend: %v total (%v/span)", spans, elapsed, elapsed/spans)
}

// provenance: derived
// verifies: observability contract -- export failures reach a structured
// logger as a WARN rather than the SDK's default unstructured stderr writer.
//
// Driven by invoking the installed handler directly. Waiting for a real
// export to fail would mean waiting out the batch timeout, which makes the
// test slow and its failure mode a timeout rather than a claim.
func TestNewTracer_OTLPRoutesExportFailuresToAStructuredLogger(t *testing.T) {
	restoreGlobals(t)
	var rec recordingHandler
	_, shutdown, err := NewTracer(context.Background(), TracerOptions{
		Mode:           TracingOTLP,
		Endpoint:       deadEndpoint,
		Logger:         discardLogger(),
		ExportFailures: slog.New(&rec),
	})
	if err != nil {
		t.Fatalf("NewTracer: %v", err)
	}
	t.Cleanup(func() { _ = shutdown(context.Background()) })

	before := rec.snapshot().count
	otel.GetErrorHandler().Handle(errors.New("simulated export failure"))
	got := rec.snapshot()
	if got.count != before+1 {
		t.Fatalf("an SDK error produced %d records on the failure sink, want 1 -- "+
			"the default handler writes unstructured text to stderr, so the one signal "+
			"that traces are being lost is the one line no log store can parse", got.count-before)
	}
	// LEVEL AND MESSAGE, not just a count. Asserting arrival alone let a
	// mutation to DebugContext stay green -- and in production that mutant is
	// the SILENT case, because the JSON lane is floored at LOG_LEVEL (info by
	// default), so the line would never be emitted at all.
	if got.lastLevel != slog.LevelWarn {
		t.Fatalf("export failure logged at %v, want WARN -- below the default LOG_LEVEL floor "+
			"the line is dropped entirely, which is the outcome this handler exists to prevent", got.lastLevel)
	}
	if !strings.Contains(got.lastMsg, "OTLP export failed") {
		t.Fatalf("export failure message = %q, want it to name an OTLP export failure", got.lastMsg)
	}
	// The message must NOT claim the signal. otel.SetErrorHandler is global
	// and the OTel LOG sdk reports through it too, so "trace export failed"
	// would page the wrong subsystem during a log-collector outage.
	if strings.Contains(got.lastMsg, "trace export failed") {
		t.Fatalf("export failure message %q names TRACES, but the OTel error handler is "+
			"process-global and the log SDK reports through it as well", got.lastMsg)
	}
}

// provenance: regression
// verifies: an OTLP export failure can never become the next export's
// payload -- the self-sustaining loop measured on this scaffold.
//
// THE DEFECT, MEASURED. otel.SetErrorHandler is PROCESS-GLOBAL and
// go.opentelemetry.io/otel/sdk/log reports its own export failures through
// it. With the handler writing through the process logger while
// LOG_EXPORT=otlp fanned that logger onto an OTLP lane, one ordinary
// InfoContext line was enough to start a permanent cycle: the WARN about the
// failed export is a log record, which is batched, which fails, which emits
// another WARN. Measured with a log collector returning 500: 19 export
// attempts and 19 WARN lines in 20 seconds, flat and non-decaying, with zero
// traces exported.
//
// The fix is structural, not a rate limit: export failures go to a logger
// that CANNOT export. This test pins that separation by requiring the
// PROCESS logger to receive nothing.
func TestNewTracer_OTLPExportFailuresNeverReachTheExportingLogLane(t *testing.T) {
	restoreGlobals(t)
	var process, failures recordingHandler
	_, shutdown, err := NewTracer(context.Background(), TracerOptions{
		Mode:           TracingOTLP,
		Endpoint:       deadEndpoint,
		Logger:         slog.New(&process),
		ExportFailures: slog.New(&failures),
	})
	if err != nil {
		t.Fatalf("NewTracer: %v", err)
	}
	t.Cleanup(func() { _ = shutdown(context.Background()) })

	atBoot := process.snapshot().count // the one "exporting traces over OTLP/HTTP" line
	for i := 0; i < 5; i++ {
		otel.GetErrorHandler().Handle(errors.New("simulated export failure"))
	}
	if n := process.snapshot().count; n != atBoot {
		t.Fatalf("%d export-failure line(s) reached the PROCESS logger -- under LOG_EXPORT=otlp "+
			"each one becomes a log record on the very lane that just failed, and a collector "+
			"outage sustains itself", n-atBoot)
	}
	if n := failures.snapshot().count; n != 5 {
		t.Fatalf("the failure sink received %d of 5 -- separating the lanes must not lose the signal", n)
	}
}

// provenance: regression
// verifies: the shutdown returned by NewTracer actually FLUSHES, and a
// well-formed reachable endpoint actually receives spans.
//
// THE ONLY TEST THAT EXERCISES THE HAPPY PATH OVER A REAL SOCKET, and it
// exists because the alternative was proven hollow: replacing the returned
// shutdown with `return nil` left the ENTIRE suite green across all packages.
// Every other assertion about shutdown required it to return nil, which
// `return nil` satisfies perfectly. The whole flush-ordering argument in
// cmd/<SERVICE>'s run() rested on a function nothing proved did anything.
//
// It also closes the gap that every other OTLP test here points at a dead or
// hung port, or swaps in an in-memory exporter: without this, "spans reach a
// collector" was asserted nowhere.
func TestNewTracer_OTLPShutdownFlushesQueuedSpansToARealCollector(t *testing.T) {
	var mu sync.Mutex
	var posts []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		posts = append(posts, r.URL.Path)
		mu.Unlock()
		w.WriteHeader(http.StatusOK)
	}))
	t.Cleanup(srv.Close)

	tr, shutdown, err := NewTracer(context.Background(), TracerOptions{
		Mode:           TracingOTLP,
		Endpoint:       strings.TrimPrefix(srv.URL, "http://"),
		ServiceName:    "svc",
		ServiceVersion: "test",
		Logger:         discardLogger(),
		ExportFailures: discardLogger(),
	})
	if err != nil {
		t.Fatalf("NewTracer against a live collector: %v", err)
	}

	_, span := tr.StartSpan(context.Background(), "svc.deposit", map[string]string{"event_type": "deposit"})
	span.End()

	// Nothing has been sent yet: the batcher holds spans until the batch
	// fills or its timer fires, and neither has happened. That is exactly why
	// the composition root MUST defer the shutdown.
	mu.Lock()
	beforeFlush := len(posts)
	mu.Unlock()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := shutdown(ctx); err != nil {
		t.Fatalf("shutdown against a live collector: %v", err)
	}

	mu.Lock()
	got := append([]string(nil), posts...)
	mu.Unlock()
	if len(got) == 0 {
		t.Fatalf("shutdown() delivered NOTHING to a reachable collector (%d posts before the flush) -- "+
			"the last batch of spans before every process exit is lost", beforeFlush)
	}
	if got[len(got)-1] != "/v1/traces" {
		t.Fatalf("collector received %v, want a POST to /v1/traces", got)
	}
}

// provenance: regression
// verifies: OTEL_TRACES_SAMPLER cannot silently take this service to zero
// traces.
//
// The SDK reads that variable when no sampler is supplied, so leaving the
// option off would create a fifth operational lever with real production
// consequences that config.Load never validates and /healthz never reports --
// the exact silent-downgrade shape TRACING_ENDPOINT is validated to prevent,
// arriving through the environment instead of through config.
func TestNewTracer_OTLPIgnoresTheSDKSamplerEnvVars(t *testing.T) {
	t.Setenv("OTEL_TRACES_SAMPLER", "always_off")

	tr, shutdown, err := NewTracer(context.Background(), TracerOptions{
		Mode:           TracingOTLP,
		Endpoint:       deadEndpoint,
		Logger:         discardLogger(),
		ExportFailures: discardLogger(),
	})
	if err != nil {
		t.Fatalf("NewTracer: %v", err)
	}
	t.Cleanup(func() { _ = shutdown(context.Background()) })

	ctx, span := tr.StartSpan(context.Background(), "svc.deposit", nil)
	defer span.End()
	if !oteltrace.SpanContextFromContext(ctx).IsSampled() {
		t.Fatal("OTEL_TRACES_SAMPLER=always_off silenced tracing: an env var this repo never " +
			"validates and never surfaces on /healthz just took the service to zero traces")
	}
}

// newRecordedOTLPTracer returns an otlpTracer backed by an in-memory SDK
// exporter plus the accessor for what it recorded.
//
// The seam exists for the same reason NewOTLPLane takes its downstream
// processor as a parameter on the logging side: the claims below ("a clean
// span is not marked failed", "an errored span is FINDABLE") are about what
// reaches a backend, and asserting them by reading the SDK's source would be
// the decorative form of the check. WithSyncer, not WithBatcher, so the
// assertion runs after End() with no flush and no sleep -- the production
// path's batching is proven separately, by the dead-backend test above.
func newRecordedOTLPTracer(t *testing.T) (Tracer, func() tracetest.SpanStubs) {
	t.Helper()
	exporter := tracetest.NewInMemoryExporter()
	provider := sdktrace.NewTracerProvider(sdktrace.WithSyncer(exporter))
	t.Cleanup(func() { _ = provider.Shutdown(context.Background()) })
	return &otlpTracer{tracer: provider.Tracer("svc")}, exporter.GetSpans
}

// provenance: regression
// verifies: observability contract -- an errored span carries BOTH the
// exception event and the Error STATUS.
//
// RecordError alone attaches an exception event and leaves the span's status
// at Unset, which every backend renders as OK and every backend's error
// filter excludes. A failed command that is recorded but not findable is a
// failed command nobody finds: the only way anyone reaches one is by
// filtering a trace list on errors.
func TestOTLPSpan_RecordErrorSetsTheStatusSoTheSpanIsFilterable(t *testing.T) {
	tr, spans := newRecordedOTLPTracer(t)

	_, span := tr.StartSpan(context.Background(), "svc.withdraw", map[string]string{"event_type": "withdraw"})
	span.RecordError(errors.New("insufficient balance"))
	span.End()

	got := spans()
	if len(got) != 1 {
		t.Fatalf("recorded %d spans, want 1", len(got))
	}
	if got[0].Status.Code != codes.Error {
		t.Fatalf("status = %v, want %v -- an errored span that reads OK is invisible to every "+
			"error filter, which is the only way anyone looks for one", got[0].Status.Code, codes.Error)
	}
	if !strings.Contains(got[0].Status.Description, "insufficient balance") {
		t.Fatalf("status description = %q, want the error text", got[0].Status.Description)
	}
	var sawException bool
	for _, e := range got[0].Events {
		if e.Name == "exception" {
			sawException = true
		}
	}
	if !sawException {
		t.Fatal("no exception event on the span -- SetStatus without RecordError loses the error's detail")
	}
}

// provenance: regression
// verifies: tracing port (RecordError(nil) is a documented no-op) on the
// EXPORTING adapter.
//
// The composition root's adaptTracer calls span.RecordError(err)
// unconditionally from a deferred close, so every SUCCESSFUL command reaches
// this method with a nil error. Drop the guard and the backend marks 100% of
// spans failed -- an error filter that selects everything, which is exactly
// as useful as one that selects nothing, and considerably more misleading.
func TestOTLPSpan_RecordErrorNilLeavesTheSpanUnmarked(t *testing.T) {
	tr, spans := newRecordedOTLPTracer(t)

	_, span := tr.StartSpan(context.Background(), "svc.deposit", nil)
	span.RecordError(nil)
	span.End()

	got := spans()
	if len(got) != 1 {
		t.Fatalf("recorded %d spans, want 1", len(got))
	}
	if got[0].Status.Code == codes.Error {
		t.Fatal("RecordError(nil) marked a clean span as failed: every successful command would " +
			"reach the backend as an error, because adaptTracer calls RecordError unconditionally")
	}
	if len(got[0].Events) != 0 {
		t.Fatalf("RecordError(nil) attached %d event(s) to a clean span", len(got[0].Events))
	}
}

// provenance: derived
// verifies: the exporting adapter carries attributes with deterministic
// ordering and parents its spans, matching the log adapter's guarantees.
func TestOTLPTracer_CarriesSortedAttributesAndParentsItsSpans(t *testing.T) {
	tr, spans := newRecordedOTLPTracer(t)

	parentCtx, parent := tr.StartSpan(context.Background(), "svc.deposit", map[string]string{
		"event_type":    "deposit",
		"config_digest": "abc123",
		"revision":      "deadbeef",
	})
	_, child := tr.StartSpan(parentCtx, "svc.child", nil)
	child.End()
	parent.End()

	got := spans()
	if len(got) != 2 {
		t.Fatalf("recorded %d spans, want 2", len(got))
	}
	// Syncer order: the child ends first.
	childSpan, parentSpan := got[0], got[1]
	if childSpan.Parent.SpanID() != parentSpan.SpanContext.SpanID() {
		t.Fatal("the child span is not parented to the span whose context StartSpan returned -- " +
			"every span would be a root, which is 3132 traces for 3132 spans")
	}
	if childSpan.SpanContext.TraceID() != parentSpan.SpanContext.TraceID() {
		t.Fatal("parent and child are in different traces")
	}

	keys := make([]string, 0, len(parentSpan.Attributes))
	for _, kv := range parentSpan.Attributes {
		keys = append(keys, string(kv.Key))
	}
	want := []string{"config_digest", "event_type", "revision"}
	if len(keys) != len(want) {
		t.Fatalf("attribute keys = %v, want %v", keys, want)
	}
	for i := range want {
		if keys[i] != want[i] {
			t.Fatalf("attribute keys = %v, want them sorted as %v", keys, want)
		}
	}
}

// provenance: derived
// verifies: the exporting adapter survives a nil context, like the log one.
//
// HONEST NOTE ON WHAT THIS PROVES. Deleting otlpTracer.StartSpan's own
// `if ctx == nil` guard leaves this test GREEN -- measured, not assumed --
// because go.opentelemetry.io/otel/trace guards nil itself
// (trace.SpanFromContext returns the noop span for a nil context). So this
// case pins a CONTRACT ("a nil context is safe here"), not that one line.
// The guard stays because the contract is currently upheld by a dependency's
// internals rather than by anything we control, and a panic raised from
// inside a deferred End() would fire while describing the failure it was
// supposed to report. Its counterpart in logTracer.StartSpan IS load-bearing:
// that adapter stores the context and hands it to slog at End.
func TestOTLPTracer_NilContextStillRecordsASpan(t *testing.T) {
	tr, spans := newRecordedOTLPTracer(t)
	var nilCtx context.Context
	ctx, span := tr.StartSpan(nilCtx, "svc.nil_ctx", nil)
	span.End()
	if ctx == nil {
		t.Fatal("StartSpan returned a nil context")
	}
	if got := spans(); len(got) != 1 || got[0].Name != "svc.nil_ctx" {
		t.Fatalf("recorded %v, want one svc.nil_ctx span", got)
	}
}

// provenance: derived
// verifies: the exported span context is a real, sampled W3C context that
// propagation.go can inject -- the join between this adapter and the half
// of tracing that crosses a boundary.
func TestOTLPTracer_ProducesAnInjectableSpanContext(t *testing.T) {
	tr, _ := newRecordedOTLPTracer(t)
	ctx, span := tr.StartSpan(context.Background(), "svc.deposit", nil)
	defer span.End()

	if sc := oteltrace.SpanContextFromContext(ctx); !sc.IsValid() {
		t.Fatal("StartSpan returned a context with no valid span context: nothing downstream can be parented to it")
	}
	if got := TraceParentFromContext(ctx); got == "" {
		t.Fatal("the span's context renders no traceparent, so no durable record can carry its provenance")
	}
}

// provenance: derived
// verifies: the exporter constructor honours the BOOT context, so a SIGTERM
// arriving mid-boot is reported rather than swallowed.
//
// cmd/<SERVICE> derives its boot context from signal.NotifyContext precisely
// so that a shutdown signal during a long recovery is observable instead of
// killing the process outright. That makes a cancelled context a REACHABLE
// state here, not a theoretical one: otlptracehttp.New returns "context
// canceled", NewTracer wraps it, and run() returns it as a boot error --
// which is the honest outcome, because a process being torn down should not
// go on to open an exporter.
func TestNewTracer_OTLPPropagatesACancelledBootContext(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	tr, shutdown, err := NewTracer(ctx, TracerOptions{
		Mode:     TracingOTLP,
		Endpoint: deadEndpoint,
		Logger:   discardLogger(),
	})
	if err == nil {
		_ = shutdown(context.Background())
		t.Fatal("a cancelled boot context still built an exporter")
	}
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("error = %v, want it to wrap context.Canceled so the caller can tell a torn-down "+
			"boot from a misconfigured endpoint", err)
	}
	if tr != nil || shutdown != nil {
		t.Fatal("a refused boot returned a non-nil tracer or shutdown")
	}
}

// provenance: regression
// verifies: every OTLP export failure is COUNTED, not only logged.
//
// The counter is what the health surface publishes as
// svc_otlp_export_failures_total, and it is the difference between an
// operator who is told telemetry is being dropped and one who has to already
// suspect it. It matters most for the case the WARN is worst at: when
// LOG_EXPORT=otlp, the thing failing to export IS the log lane, so the log
// line saying so is the least reliable way to learn it.
func TestNewTracer_OTLPCountsEveryExportFailure(t *testing.T) {
	restoreGlobals(t)
	_, shutdown, err := NewTracer(context.Background(), TracerOptions{
		Mode:           TracingOTLP,
		Endpoint:       deadEndpoint,
		Logger:         discardLogger(),
		ExportFailures: discardLogger(),
	})
	if err != nil {
		t.Fatalf("NewTracer: %v", err)
	}
	t.Cleanup(func() { _ = shutdown(context.Background()) })

	before := OTLPExportFailures()
	for i := 0; i < 3; i++ {
		otel.GetErrorHandler().Handle(errors.New("simulated export failure"))
	}
	if got := OTLPExportFailures() - before; got != 3 {
		t.Fatalf("OTLPExportFailures rose by %d over 3 failures -- a series stuck at 0 while "+
			"exports fail is exactly the shape that makes a healthy-looking dashboard meaningless", got)
	}
}
