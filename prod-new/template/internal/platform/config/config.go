// Package config loads this service's env-driven configuration.
package config

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

// Config is a pod's full configuration.
type Config struct {
	// HealthPort serves /healthz, /readyz and /metrics.
	HealthPort int
	// PodID identifies this process in logs/spans. Defaults to HOSTNAME.
	PodID string
	// EventLogPath is where the append-only event log is written. Env
	// EVENTLOG_PATH.
	EventLogPath string
	// InvariantViolationCooldown bounds how long a detected invariant
	// violation keeps /readyz failing after the last one observed -- the
	// rollback lever documented in registries/flags.yaml. Env
	// INVARIANT_COOLDOWN_S (seconds); "0" disables the readiness gate
	// entirely (still counted, never gates).
	InvariantViolationCooldown time.Duration
	// OutboxMaxAttempts bounds how many delivery attempts the outbox makes
	// per entry before giving up and marking it failed (still counted;
	// never retried forever). Env OUTBOX_MAX_ATTEMPTS.
	OutboxMaxAttempts int
	// Tracing selects the observability.Tracer the composition root wires
	// into every adapter (see observability/tracing-contract equivalent:
	// package doc of internal/platform/observability). Env TRACING: unset
	// or "off" -> "off" (observability.NewNoop(), the default, costs
	// nothing); "log" -> a structured-log Tracer. Any other value is a boot
	// error -- fail closed on a typo'd config rather than silently falling
	// back to noop.
	Tracing string
	// PprofPort, when non-zero, serves net/http/pprof on its own listener.
	// Env PPROF_PORT; unset/0 means pprof is not served at all -- the
	// documented default-off rollback lever (registries/flags.yaml).
	PprofPort int
}

// Load builds a Config from the environment with sane defaults.
func Load() (Config, error) {
	c := Config{
		HealthPort:                 8081,
		PodID:                      os.Getenv("HOSTNAME"),
		EventLogPath:               "data/eventlog.jsonl",
		InvariantViolationCooldown: 30 * time.Second,
		OutboxMaxAttempts:          5,
		Tracing:                    "off",
	}
	if v := os.Getenv("HEALTH_PORT"); v != "" {
		p, err := strconv.Atoi(v)
		if err != nil {
			return Config{}, fmt.Errorf("HEALTH_PORT: %w", err)
		}
		c.HealthPort = p
	}
	if v := os.Getenv("EVENTLOG_PATH"); strings.TrimSpace(v) != "" {
		c.EventLogPath = v
	}
	if v := os.Getenv("INVARIANT_COOLDOWN_S"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil {
			return Config{}, fmt.Errorf("INVARIANT_COOLDOWN_S: %w", err)
		}
		c.InvariantViolationCooldown = time.Duration(n) * time.Second
	}
	if v := os.Getenv("OUTBOX_MAX_ATTEMPTS"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil {
			return Config{}, fmt.Errorf("OUTBOX_MAX_ATTEMPTS: %w", err)
		}
		if n <= 0 {
			return Config{}, fmt.Errorf("OUTBOX_MAX_ATTEMPTS: must be > 0")
		}
		c.OutboxMaxAttempts = n
	}
	if v := os.Getenv("PPROF_PORT"); v != "" {
		p, err := strconv.Atoi(v)
		if err != nil {
			return Config{}, fmt.Errorf("PPROF_PORT: %w", err)
		}
		c.PprofPort = p
	}
	tracing, err := ParseTracing(os.Getenv("TRACING"))
	if err != nil {
		return Config{}, err
	}
	c.Tracing = tracing
	if c.PodID == "" {
		c.PodID = "svc-local"
	}
	return c, nil
}

// ParseTracing validates and canonicalizes a raw TRACING env value: unset/
// empty -> "off"; "off" or "log" pass through unchanged; anything else is a
// boot error.
func ParseTracing(raw string) (string, error) {
	v := strings.TrimSpace(raw)
	if v == "" {
		return "off", nil
	}
	switch v {
	case "off", "log":
		return v, nil
	default:
		return "", fmt.Errorf("TRACING: must be \"off\" or \"log\" (got %q)", v)
	}
}
