// Direct dependencies, and why a scaffold that had NONE now has these.
//
// Every entry below exists to make logs joinable to traces. The trade was
// made deliberately and is worth stating, because "add no dependency" is the
// default this file used to satisfy trivially:
//
//   - otelslog is the OpenTelemetry log bridge. Without it the OTLP lane
//     would be a bespoke exporter -- more code, less compatibility, and a
//     format the collector would have to be taught.
//   - minsev floors that lane at INFO so LOG_LEVEL=debug cannot put debug
//     traffic on the wire (~834 B/record).
//   - otlploghttp is the exporter itself. Wiring the bridge to the GLOBAL
//     LoggerProvider instead would have added no dependency and shipped a
//     lane that converts every record and drops it -- instrumented, never
//     wired, which is the exact defect this repo's probes exist to catch.
//   - otel/sdk/log, otel/sdk and otel are what those three need to build a
//     LoggerProvider with a resource; otel/trace is read directly by
//     observability.traceHandler to stamp trace_id/span_id on the stdout
//     lane.
//   - otlptracehttp CLOSES THE OTHER HALF OF THAT SENTENCE. Everything above
//     stamps a trace_id onto a log line; without a trace exporter that id
//     names a trace no backend has ever been told about. Shipping the log
//     bridge alone was worse than shipping neither: an absent trace_id reads
//     as "outside a span", while a present one that 404s reads as "your query
//     is wrong", and people believe it. See
//     internal/platform/observability/otlp_tracer.go.
//
// NOTE ON MATURITY: OpenTelemetry Go's LOGS signal is BETA
// (go.opentelemetry.io/otel/log is v0.x) while traces and metrics are
// Stable v1.x. Expect breaking changes across minor bumps of the v0.x
// modules, and pin them.
module github.com/<OWNER>/<SERVICE>

go 1.26.6

require (
	go.opentelemetry.io/contrib/bridges/otelslog v0.20.0
	go.opentelemetry.io/contrib/processors/minsev v0.16.2
	go.opentelemetry.io/otel v1.45.0
	go.opentelemetry.io/otel/exporters/otlp/otlplog/otlploghttp v0.21.0
	go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp v1.45.0
	go.opentelemetry.io/otel/sdk v1.45.0
	go.opentelemetry.io/otel/sdk/log v0.21.0
	go.opentelemetry.io/otel/trace v1.45.0
)

require (
	github.com/cenkalti/backoff/v5 v5.0.3 // indirect
	github.com/cespare/xxhash/v2 v2.3.0 // indirect
	github.com/go-logr/logr v1.4.4 // indirect
	github.com/go-logr/stdr v1.2.2 // indirect
	github.com/google/uuid v1.6.0 // indirect
	github.com/grpc-ecosystem/grpc-gateway/v2 v2.29.0 // indirect
	go.opentelemetry.io/auto/sdk v1.2.1 // indirect
	go.opentelemetry.io/otel/exporters/otlp/otlptrace v1.45.0 // indirect
	go.opentelemetry.io/otel/log v0.21.0 // indirect
	go.opentelemetry.io/otel/metric v1.45.0 // indirect
	go.opentelemetry.io/proto/otlp v1.11.0 // indirect
	golang.org/x/net v0.57.0 // indirect
	golang.org/x/sys v0.47.0 // indirect
	golang.org/x/text v0.40.0 // indirect
	google.golang.org/genproto/googleapis/api v0.0.0-20260803160001-6ac0973c030d // indirect
	google.golang.org/genproto/googleapis/rpc v0.0.0-20260803160001-6ac0973c030d // indirect
	google.golang.org/grpc v1.83.0 // indirect
	google.golang.org/protobuf v1.36.11 // indirect
)
