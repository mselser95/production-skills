// Package config loads service settings from a key=value file with
// environment overrides.
package config

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"
	"time"
)

// ErrSyntax is returned for a line that is not key=value.
var ErrSyntax = errors.New("config syntax error")

// Config holds the service settings.
type Config struct {
	Addr    string
	Workers int
	Timeout time.Duration
}

// Defaults returns the settings used when nothing is configured.
func Defaults() Config {
	return Config{Addr: ":8080", Workers: 4, Timeout: 5 * time.Second}
}

// Parse reads key=value lines from r over the defaults. Blank lines and lines
// starting with # are skipped.
func Parse(r io.Reader) (Config, error) {
	cfg := Defaults()
	sc := bufio.NewScanner(r)
	for n := 1; sc.Scan(); n++ {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			return Config{}, fmt.Errorf("line %d: %w", n, ErrSyntax)
		}
		if err := set(&cfg, strings.TrimSpace(k), strings.TrimSpace(v)); err != nil {
			return Config{}, fmt.Errorf("line %d: %w", n, err)
		}
	}
	return cfg, sc.Err()
}

func set(c *Config, key, val string) error {
	switch key {
	case "addr":
		c.Addr = val
	case "workers":
		n, err := strconv.Atoi(val)
		if err != nil || n < 1 {
			return fmt.Errorf("workers %q: %w", val, ErrSyntax)
		}
		c.Workers = n
	case "timeout":
		d, err := time.ParseDuration(val)
		if err != nil || d <= 0 {
			return fmt.Errorf("timeout %q: %w", val, ErrSyntax)
		}
		c.Timeout = d
	default:
		return fmt.Errorf("unknown key %q: %w", key, ErrSyntax)
	}
	return nil
}
