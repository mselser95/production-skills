// Package config loads this service's env-driven configuration.
package config

import (
	"fmt"
	"log/slog"
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
	// OutboxLogPath is where the outbox's durable journal lives. Env
	// OUTBOX_LOG_PATH.
	//
	// Separate from EventLogPath on purpose: the two have different
	// retention needs (the event log is history, the outbox is in-flight
	// work) and compacting one must not require understanding the other.
	OutboxLogPath string
	// OutboxMaxAttempts bounds how many delivery attempts the outbox makes
	// per entry before giving up and marking it failed (still counted;
	// never retried forever). Env OUTBOX_MAX_ATTEMPTS.
	OutboxMaxAttempts int
	// CheckpointPath is where the relay's durable position lives. Separate
	// from the event log because it is a READER's bookmark, not history: it
	// is rewritten in place, and losing it costs a republish rather than a
	// loss. Env CHECKPOINT_PATH.
	CheckpointPath string
	// PublishTopic is the topic integration events are published to. Env
	// PUBLISH_TOPIC.
	PublishTopic string
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
	// LogLevel is the floor for the process's JSON log lane. Env
	// LOG_LEVEL: "debug", "info" (default), "warn" or "error". Any other
	// value is a boot error, for the same reason TRACING is: an operator
	// who sets LOG_LEVEL=verbose during an incident and gets silence has
	// been told nothing, and has spent the one thing an incident is short
	// of.
	LogLevel slog.Level
	// LogExport selects the OTLP log lane the composition root fans
	// records out to. Env LOG_EXPORT: unset or "off" -> "off" (JSON to
	// stdout only, the default: a service with no collector in front of it
	// must not pay for an exporter that has nowhere to send); "otlp" ->
	// additionally ship to OTEL_EXPORTER_OTLP_ENDPOINT. Any other value is
	// a boot error.
	//
	// This is the second half of the knob otlpMinSeverity documents in
	// internal/platform/observability: the OTLP lane costs ~834 B per
	// record on the wire, so it is opt-in per deployment rather than a
	// default every scaffold inherits.
	LogExport string
}

// Load builds a Config from the environment with sane defaults.
func Load() (Config, error) {
	c := Config{
		HealthPort:                 8081,
		PodID:                      os.Getenv("HOSTNAME"),
		EventLogPath:               "data/eventlog.jsonl",
		InvariantViolationCooldown: 30 * time.Second,
		OutboxLogPath:              "data/outbox.jsonl",
		OutboxMaxAttempts:          5,
		CheckpointPath:             "data/checkpoints.json",
		PublishTopic:               "svc.events",
		Tracing:                    "off",
		LogLevel:                   slog.LevelInfo,
		LogExport:                  LogExportOff,
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
	if v := strings.TrimSpace(os.Getenv("OUTBOX_LOG_PATH")); v != "" {
		c.OutboxLogPath = v
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
	level, err := ParseLogLevel(os.Getenv("LOG_LEVEL"))
	if err != nil {
		return Config{}, err
	}
	c.LogLevel = level
	export, err := ParseLogExport(os.Getenv("LOG_EXPORT"))
	if err != nil {
		return Config{}, err
	}
	c.LogExport = export
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

// Log export modes. These mirror internal/platform/observability's
// LogExportOff/LogExportOTLP and are re-declared here rather than imported
// so config stays a leaf package that every layer may read.
const (
	LogExportOff  = "off"
	LogExportOTLP = "otlp"
)

// ParseLogLevel validates and canonicalizes a raw LOG_LEVEL env value:
// unset/empty -> slog.LevelInfo; "debug"/"info"/"warn"/"error"
// (case-insensitive) map to their slog levels; anything else is a boot
// error.
//
// Deliberately NOT slog.Level.UnmarshalText, which also accepts offsets
// like "INFO+2". Those are legal slog and unreadable as an operational
// contract: nobody can say from a dashboard what "INFO+2" suppresses.
func ParseLogLevel(raw string) (slog.Level, error) {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "":
		return slog.LevelInfo, nil
	case "debug":
		return slog.LevelDebug, nil
	case "info":
		return slog.LevelInfo, nil
	case "warn":
		return slog.LevelWarn, nil
	case "error":
		return slog.LevelError, nil
	default:
		return 0, fmt.Errorf("LOG_LEVEL: must be \"debug\", \"info\", \"warn\" or \"error\" (got %q)", raw)
	}
}

// ParseLogExport validates and canonicalizes a raw LOG_EXPORT env value:
// unset/empty -> LogExportOff; "off" or "otlp" pass through; anything else
// is a boot error.
func ParseLogExport(raw string) (string, error) {
	v := strings.TrimSpace(raw)
	if v == "" {
		return LogExportOff, nil
	}
	switch v {
	case LogExportOff, LogExportOTLP:
		return v, nil
	default:
		return "", fmt.Errorf("LOG_EXPORT: must be %q or %q (got %q)", LogExportOff, LogExportOTLP, raw)
	}
}
