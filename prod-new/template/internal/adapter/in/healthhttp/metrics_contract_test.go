package healthhttp

import (
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strings"
	"testing"
)

// provenance: derived
// verifies: observability contract (tier-policy: observability_contract
// required, checked in CI, not documentation)
//
// Mechanically verifies observability/emitted-metrics.yaml against the real
// /metrics exposition in BOTH directions: every series the scrape actually
// contains must be declared in the manifest, and every series
// MetricNames() declares this handler can emit must appear in the scrape.
// Drives the real health server against real Options so every series this
// exposition can produce actually appears.
func TestMetricsContract_ScrapeMatchesManifestBothDirections(t *testing.T) {
	manifest := parseMetricsManifest(t, manifestPath(t))

	srv := New(fakeLedger{conservation: 1, duplicate: 1}, Options{Log: fakeLog{writable: true}})
	base := serveTest(t, srv)

	resp, err := http.Get(base + "/metrics")
	if err != nil {
		t.Fatalf("get /metrics: %v", err)
	}
	defer func() { _ = resp.Body.Close() }()
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read body: %v", err)
	}
	scraped := scrapeSeries(t, string(raw))

	for name := range scraped {
		if !manifest[name] {
			t.Errorf("scrape emits series %q that observability/emitted-metrics.yaml does not declare -- undeclared metric drift", name)
		}
	}
	for _, name := range MetricNames() {
		if !scraped[name] {
			t.Errorf("MetricNames() declares series %q but the scrape never emitted it", name)
		}
		if !manifest[name] {
			t.Errorf("MetricNames() declares series %q but observability/emitted-metrics.yaml does not -- the manifest has drifted behind the code", name)
		}
	}
	for name := range manifest {
		found := false
		for _, n := range MetricNames() {
			if n == name {
				found = true
				break
			}
		}
		if !found {
			t.Errorf("observability/emitted-metrics.yaml declares series %q that this handler's MetricNames() does not know about -- the manifest has drifted AHEAD of the code", name)
		}
	}
}

func manifestPath(t *testing.T) string {
	t.Helper()
	return filepath.Join(repoRoot(t), "observability", "emitted-metrics.yaml")
}

func repoRoot(t *testing.T) string {
	t.Helper()
	_, currentFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot locate this test file")
	}
	// this file: internal/adapter/in/healthhttp/metrics_contract_test.go
	return filepath.Clean(filepath.Join(filepath.Dir(currentFile), "..", "..", "..", ".."))
}

var manifestNameRe = regexp.MustCompile(`^- name:\s*(\S+)\s*$`)

func parseMetricsManifest(t *testing.T, path string) map[string]bool {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	out := map[string]bool{}
	for _, line := range strings.Split(string(data), "\n") {
		if m := manifestNameRe.FindStringSubmatch(line); m != nil {
			out[m[1]] = true
		}
	}
	if len(out) == 0 {
		t.Fatalf("parsed zero series names from %s -- format changed or the scanner broke", path)
	}
	return out
}

var seriesNameRe = regexp.MustCompile(`^([a-zA-Z_:][a-zA-Z0-9_:]*)`)

// scrapeSeries returns every distinct series NAME present in a Prometheus
// text-exposition body (sample lines only, HELP/TYPE comments ignored).
func scrapeSeries(t *testing.T, body string) map[string]bool {
	t.Helper()
	out := map[string]bool{}
	for _, line := range strings.Split(body, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		m := seriesNameRe.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		out[m[1]] = true
	}
	names := make([]string, 0, len(out))
	for n := range out {
		names = append(names, n)
	}
	sort.Strings(names) // deterministic iteration for any future debug print
	return out
}
