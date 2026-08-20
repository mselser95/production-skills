package config

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
)

// Digest returns a short, deterministic fingerprint of every field in c.
//
// This is the "config Y" leg of the operational-determinism contract:
// production output is F(code, config, state, inputs), and a trace must be
// able to answer "this ran with commit X, config Y" (internal/platform/
// buildinfo answers "commit X"). json.Marshal walks a struct's fields in
// fixed declaration order, so encoding the same Config value always
// produces the same bytes: this hash is a pure function of c, stable across
// restarts given an identical resolved config, and changes the moment any
// field's live value changes. sha256 truncated to 12 hex chars: short
// enough for a metric label, a log line, or a span attribute.
//
// provenance: derived
// verifies: operational determinism (Output = F(code, config, state,
// inputs), all versioned)
func (c Config) Digest() string {
	return Digest(c)
}

// Identity is the small set of behavior-defining flags whose LIVE values
// must be observable without reading process env or source directly,
// mirrored on the documented rollback levers (registries/flags.yaml), plus
// Digest, the fingerprint of every OTHER field. Surfaced on /healthz, the
// build_info metric, and every tracing span's base attributes so a replay
// never has to guess which config produced a result.
type Identity struct {
	Digest             string `json:"digest"`
	InvariantCooldownS int    `json:"invariant_cooldown_s"`
	OutboxMaxAttempts  int    `json:"outbox_max_attempts"`
	Tracing            string `json:"tracing"`
	// TracingEndpoint turns "is this pod exporting traces, and to where?"
	// into a lookup instead of a guess. Tracing alone cannot answer it: a
	// pod reading `"tracing":"otlp"` is exporting SOMEWHERE, and the whole
	// class of defect this scaffold cares about is the endpoint that is
	// syntactically fine and points at nothing. Empty whenever Tracing is
	// not "otlp", which is itself the answer to the question.
	TracingEndpoint string `json:"tracing_endpoint"`
	PprofPort       int    `json:"pprof_port"`
	// LogLevel and LogExport are here because a log store answering
	// "there are no DEBUG lines" is ambiguous: it can mean the code never
	// logged one, or that this pod was started at INFO, or that the OTLP
	// lane was off entirely. Surfacing both live values turns that
	// ambiguity into a lookup. snake_case JSON like every other key on this
	// struct -- see the label-naming note in observability.traceHandler.
	LogLevel  string `json:"log_level"`
	LogExport string `json:"log_export"`
}

// Identity builds the Identity view of c.
//
// provenance: derived
// verifies: operational determinism (Output = F(code, config, state,
// inputs), all versioned)
func (c Config) Identity() Identity {
	return Identity{
		Digest:             c.Digest(),
		InvariantCooldownS: int(c.InvariantViolationCooldown.Seconds()),
		OutboxMaxAttempts:  c.OutboxMaxAttempts,
		Tracing:            c.Tracing,
		TracingEndpoint:    c.TracingEndpoint,
		PprofPort:          c.PprofPort,
		LogLevel:           c.LogLevel.String(),
		LogExport:          c.LogExport,
	}
}

// Digest returns a short, deterministic fingerprint of any resolved
// configuration value, using the same algorithm as Config.Digest.
//
// provenance: derived
// verifies: operational determinism (Output = F(code, config, state,
// inputs), all versioned)
func Digest(v any) string {
	b, err := json.Marshal(v)
	if err != nil {
		return "digest-error"
	}
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])[:12]
}
