package pprofhttp

import (
	"context"
	"net"
	"net/http"
	"testing"
)

// provenance: derived
// verifies: profiling (tier-policy dimension: capture path AND live
// endpoint) -- the live endpoint half. benchmarks/profile.sh is the
// capture-path half.
func TestServeListener_ServesPprofIndex(t *testing.T) {
	lis, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go func() { _ = ServeListener(ctx, lis) }()

	resp, err := http.Get("http://" + lis.Addr().String() + "/debug/pprof/")
	if err != nil {
		t.Fatalf("get /debug/pprof/: %v", err)
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}
}
