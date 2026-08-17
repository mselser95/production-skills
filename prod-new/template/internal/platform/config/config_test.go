package config

import "testing"

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
	c := Config{OutboxMaxAttempts: 7, Tracing: "log", PprofPort: 6060}
	id := c.Identity()
	if id.OutboxMaxAttempts != 7 || id.Tracing != "log" || id.PprofPort != 6060 {
		t.Fatalf("Identity() = %+v, want mirrored fields", id)
	}
	if id.Digest != c.Digest() {
		t.Fatalf("Identity().Digest = %q, want c.Digest() = %q", id.Digest, c.Digest())
	}
}
