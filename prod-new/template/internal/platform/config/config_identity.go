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
	PprofPort          int    `json:"pprof_port"`
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
		PprofPort:          c.PprofPort,
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
