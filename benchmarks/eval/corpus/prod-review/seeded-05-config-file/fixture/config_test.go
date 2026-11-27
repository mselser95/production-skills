package config

import (
	"errors"
	"strings"
	"testing"
	"time"
)

func TestParse(t *testing.T) {
	cfg, err := Parse(strings.NewReader("# svc\naddr = :9000\nworkers=8\n\ntimeout=2s\n"))
	if err != nil {
		t.Fatal(err)
	}
	want := Config{Addr: ":9000", Workers: 8, Timeout: 2 * time.Second}
	if cfg != want {
		t.Fatalf("cfg = %+v, want %+v", cfg, want)
	}
}

func TestParseRejects(t *testing.T) {
	for _, in := range []string{"addr", "workers=0", "timeout=-1s", "color=red"} {
		if _, err := Parse(strings.NewReader(in)); !errors.Is(err, ErrSyntax) {
			t.Fatalf("%q: err = %v, want ErrSyntax", in, err)
		}
	}
}

func TestApplyEnv(t *testing.T) {
	cfg := Defaults()
	env := map[string]string{"APP_WORKERS": "16", "APP_ADDR": ""}
	if err := ApplyEnv(&cfg, func(k string) string { return env[k] }); err != nil {
		t.Fatal(err)
	}
	if cfg.Workers != 16 || cfg.Addr != ":8080" {
		t.Fatalf("cfg = %+v", cfg)
	}
}
