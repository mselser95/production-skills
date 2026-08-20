package config

import (
	"log/slog"
	"testing"
)

// provenance: derived
// verifies: config loading defaults + env overrides
func TestLoad_Defaults(t *testing.T) {
	t.Setenv("HEALTH_PORT", "")
	t.Setenv("TRACING", "")
	c, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if c.HealthPort != 8081 {
		t.Fatalf("HealthPort = %d, want 8081", c.HealthPort)
	}
	if c.Tracing != "off" {
		t.Fatalf("Tracing = %q, want off", c.Tracing)
	}
	if c.OutboxMaxAttempts != 5 {
		t.Fatalf("OutboxMaxAttempts = %d, want 5", c.OutboxMaxAttempts)
	}
}

// provenance: derived
// verifies: config loading (env override + boot-error validation)
func TestLoad_EnvOverridesAndValidation(t *testing.T) {
	t.Setenv("HEALTH_PORT", "9999")
	t.Setenv("TRACING", "log")
	t.Setenv("OUTBOX_MAX_ATTEMPTS", "3")
	c, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if c.HealthPort != 9999 || c.Tracing != "log" || c.OutboxMaxAttempts != 3 {
		t.Fatalf("got %+v, want overridden values", c)
	}

	t.Setenv("TRACING", "not-a-real-mode")
	if _, err := Load(); err == nil {
		t.Fatal("Load() with an invalid TRACING value did not error")
	}

	t.Setenv("TRACING", "off")
	t.Setenv("OUTBOX_MAX_ATTEMPTS", "0")
	if _, err := Load(); err == nil {
		t.Fatal("Load() with OUTBOX_MAX_ATTEMPTS=0 did not error")
	}
}

// provenance: derived
// verifies: config loading (every malformed-integer env var fails closed)
func TestLoad_MalformedIntegersFailClosed(t *testing.T) {
	cases := []struct{ env, value string }{
		{"HEALTH_PORT", "not-a-port"},
		{"INVARIANT_COOLDOWN_S", "not-a-duration"},
		{"OUTBOX_MAX_ATTEMPTS", "not-a-number"},
		{"PPROF_PORT", "not-a-port"},
	}
	for _, tc := range cases {
		t.Run(tc.env, func(t *testing.T) {
			t.Setenv(tc.env, tc.value)
			if _, err := Load(); err == nil {
				t.Fatalf("Load() with %s=%q did not error", tc.env, tc.value)
			}
		})
	}
}

// provenance: derived
// verifies: config loading (EVENTLOG_PATH override)
func TestLoad_EventLogPathOverride(t *testing.T) {
	t.Setenv("EVENTLOG_PATH", "/tmp/custom-eventlog.jsonl")
	c, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if c.EventLogPath != "/tmp/custom-eventlog.jsonl" {
		t.Fatalf("EventLogPath = %q, want the overridden value", c.EventLogPath)
	}
}

// provenance: derived
// verifies: operational determinism (Config.Digest is stable and sensitive)
func TestConfig_DigestIsStableAndSensitiveToEveryField(t *testing.T) {
	a := Config{HealthPort: 8081, Tracing: "off", OutboxMaxAttempts: 5}
	b := Config{HealthPort: 8081, Tracing: "off", OutboxMaxAttempts: 5}
	if a.Digest() != b.Digest() {
		t.Fatal("Digest is not stable across two identical Config values")
	}
	c := Config{HealthPort: 8082, Tracing: "off", OutboxMaxAttempts: 5}
	if a.Digest() == c.Digest() {
		t.Fatal("Digest did not change when HealthPort changed")
	}
}

// provenance: derived
// verifies: operational determinism (Identity mirrors the rollback-lever
// fields plus Digest)
func TestConfig_Identity(t *testing.T) {
	c := Config{OutboxMaxAttempts: 7, Tracing: TracingOTLP, TracingEndpoint: "tempo:4318", PprofPort: 6060, LogLevel: slog.LevelWarn, LogExport: LogExportOTLP}
	id := c.Identity()
	if id.OutboxMaxAttempts != 7 || id.Tracing != TracingOTLP || id.PprofPort != 6060 {
		t.Fatalf("Identity() = %+v, want mirrored fields", id)
	}
	// "is this pod exporting traces, and to where?" must be a lookup, not a
	// guess: the mode alone says spans go SOMEWHERE, and the endpoint that
	// is syntactically fine and points at nothing is the whole defect class.
	if id.TracingEndpoint != "tempo:4318" {
		t.Fatalf("Identity() = %+v, want the live trace endpoint mirrored", id)
	}
	// "there are no DEBUG lines" is ambiguous without these two: it can
	// mean the code never logged one, or that this pod runs at WARN, or
	// that the exported lane was off.
	if id.LogLevel != "WARN" || id.LogExport != LogExportOTLP {
		t.Fatalf("Identity() = %+v, want the live log level and export mode mirrored", id)
	}
	if id.Digest != c.Digest() {
		t.Fatalf("Identity().Digest = %q, want c.Digest() = %q", id.Digest, c.Digest())
	}
}

// provenance: derived
// verifies: OUTBOX_LOG_PATH is read, and its default is a real path rather
// than empty.
//
// An empty default would be worse than a wrong one: store.OpenDurable on an
// empty path fails at boot, so a scaffolded service would refuse to start for
// a reason that reads like a code bug rather than a missing setting.
func TestLoad_OutboxLogPath(t *testing.T) {
	t.Setenv("OUTBOX_LOG_PATH", "")
	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.OutboxLogPath == "" {
		t.Fatal("OutboxLogPath defaults to empty -- OpenDurable would fail the boot")
	}
	if cfg.OutboxLogPath == cfg.EventLogPath {
		t.Fatalf("the outbox and event logs share the path %q -- they have different "+
			"retention needs and compacting one must not require understanding the other",
			cfg.OutboxLogPath)
	}

	t.Setenv("OUTBOX_LOG_PATH", "/tmp/custom-outbox.jsonl")
	cfg, err = Load()
	if err != nil {
		t.Fatalf("Load with an override: %v", err)
	}
	if cfg.OutboxLogPath != "/tmp/custom-outbox.jsonl" {
		t.Errorf("OutboxLogPath = %q, want the override", cfg.OutboxLogPath)
	}
}

// provenance: derived
// verifies: fail-closed config -- a typo'd LOG_LEVEL is a boot error, not a
// silent fallback.
//
// The failure this prevents is specific and expensive: an operator sets
// LOG_LEVEL=verbose mid-incident, sees no new lines, and concludes the code
// does not log what they need. A boot error says "that is not a level" in
// the one second it takes to read it.
func TestParseLogLevel(t *testing.T) {
	for raw, want := range map[string]slog.Level{
		"":       slog.LevelInfo,
		" ":      slog.LevelInfo,
		"debug":  slog.LevelDebug,
		"DEBUG":  slog.LevelDebug,
		"info":   slog.LevelInfo,
		"warn":   slog.LevelWarn,
		" ERROR": slog.LevelError,
	} {
		got, err := ParseLogLevel(raw)
		if err != nil {
			t.Fatalf("ParseLogLevel(%q): %v", raw, err)
		}
		if got != want {
			t.Fatalf("ParseLogLevel(%q) = %v, want %v", raw, got, want)
		}
	}
	// slog's own UnmarshalText accepts these; this parser deliberately does
	// not, because nobody can say from a dashboard what INFO+2 suppresses.
	for _, raw := range []string{"verbose", "INFO+2", "trace", "9"} {
		if _, err := ParseLogLevel(raw); err == nil {
			t.Fatalf("ParseLogLevel(%q) accepted an unknown level", raw)
		}
	}
}

// provenance: derived
// verifies: fail-closed config -- LOG_EXPORT is off by default and rejects
// anything it does not implement.
func TestParseLogExport(t *testing.T) {
	for _, raw := range []string{"", "  "} {
		got, err := ParseLogExport(raw)
		if err != nil || got != LogExportOff {
			t.Fatalf("ParseLogExport(%q) = %q, %v; want %q, nil", raw, got, err, LogExportOff)
		}
	}
	for _, raw := range []string{LogExportOff, LogExportOTLP} {
		got, err := ParseLogExport(raw)
		if err != nil || got != raw {
			t.Fatalf("ParseLogExport(%q) = %q, %v", raw, got, err)
		}
	}
	for _, raw := range []string{"OTLP", "stdout", "on", "true"} {
		if _, err := ParseLogExport(raw); err == nil {
			t.Fatalf("ParseLogExport(%q) accepted an unimplemented mode", raw)
		}
	}
}

// provenance: derived
// verifies: fail-closed config -- Load surfaces a bad LOG_LEVEL/LOG_EXPORT
// as a boot error rather than defaulting past it.
func TestLoad_RejectsBadLogEnv(t *testing.T) {
	t.Setenv("LOG_LEVEL", "verbose")
	if _, err := Load(); err == nil {
		t.Fatal("Load accepted LOG_LEVEL=verbose")
	}
	t.Setenv("LOG_LEVEL", "debug")
	t.Setenv("LOG_EXPORT", "carrier-pigeon")
	if _, err := Load(); err == nil {
		t.Fatal("Load accepted LOG_EXPORT=carrier-pigeon")
	}
	t.Setenv("LOG_EXPORT", LogExportOTLP)
	c, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if c.LogLevel != slog.LevelDebug || c.LogExport != LogExportOTLP {
		t.Fatalf("Load() log config = %v/%q, want DEBUG/%q", c.LogLevel, c.LogExport, LogExportOTLP)
	}
}

// provenance: regression
// verifies: fail-closed configuration -- TRACING=otlp without an endpoint
// refuses the boot instead of degrading to no export.
//
// The degraded form is the dangerous one and it is invisible: the service
// starts, logging.go stamps every line with a trace_id, and every one of
// those ids resolves to nothing in the backend. An operator reading a
// trace_id has no way to tell "the trace is elsewhere" from "there is no
// trace", so they conclude their query is wrong.
func TestLoad_TracingOTLPRequiresAnEndpoint(t *testing.T) {
	t.Setenv("TRACING", TracingOTLP)
	t.Setenv("TRACING_ENDPOINT", "")
	if _, err := Load(); err == nil {
		t.Fatal("TRACING=otlp with no TRACING_ENDPOINT booted instead of failing closed")
	}

	t.Setenv("TRACING_ENDPOINT", "tempo:4318")
	c, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if c.Tracing != TracingOTLP || c.TracingEndpoint != "tempo:4318" {
		t.Fatalf("got Tracing=%q Endpoint=%q, want otlp/tempo:4318", c.Tracing, c.TracingEndpoint)
	}

	// The endpoint is read whatever the mode is -- it is simply unused --
	// so a deployment can pre-seed it before flipping TRACING.
	t.Setenv("TRACING", TracingOff)
	c, err = Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if c.TracingEndpoint != "tempo:4318" {
		t.Fatalf("TracingEndpoint = %q, want it read regardless of mode", c.TracingEndpoint)
	}
}

// provenance: derived
// verifies: TRACING accepts exactly the three modes the observability
// package implements, and nothing else.
func TestParseTracing_AcceptsExactlyTheImplementedModes(t *testing.T) {
	for raw, want := range map[string]string{"": TracingOff, "off": TracingOff, "log": TracingLog, "otlp": TracingOTLP, "  otlp  ": TracingOTLP} {
		got, err := ParseTracing(raw)
		if err != nil {
			t.Fatalf("ParseTracing(%q): %v", raw, err)
		}
		if got != want {
			t.Fatalf("ParseTracing(%q) = %q, want %q", raw, got, want)
		}
	}
	for _, raw := range []string{"OTLP", "otel", "jaeger", "on", "true"} {
		if _, err := ParseTracing(raw); err == nil {
			t.Fatalf("ParseTracing(%q) accepted a mode nothing implements: a typo'd TRACING would "+
				"silently produce no tracing at all", raw)
		}
	}
}
