// Package pprofhttp serves net/http/pprof on its OWN listener, gated by
// config.Config.PprofPort (env PPROF_PORT). Unset/0 means it is never
// started at all -- the documented default-off rollback lever
// (registries/flags.yaml). Kept on a separate port/listener from
// healthhttp's mux deliberately: pprof handlers are diagnostic surface,
// never meant to share a port with a readiness probe a load balancer polls.
package pprofhttp

import (
	"context"
	"errors"
	"net"
	"net/http"
	"net/http/pprof"
	"time"
)

// ServeListener serves the standard net/http/pprof handlers on an
// already-bound listener until ctx is cancelled, then gracefully shuts
// down. Mirrors healthhttp.Server.ServeListener's bind-and-hand-over
// discipline.
func ServeListener(ctx context.Context, lis net.Listener) error {
	mux := http.NewServeMux()
	mux.HandleFunc("/debug/pprof/", pprof.Index)
	mux.HandleFunc("/debug/pprof/cmdline", pprof.Cmdline)
	mux.HandleFunc("/debug/pprof/profile", pprof.Profile)
	mux.HandleFunc("/debug/pprof/symbol", pprof.Symbol)
	mux.HandleFunc("/debug/pprof/trace", pprof.Trace)

	// ReadHeaderTimeout is the Slowloris defence: without it a client can
	// hold a connection open indefinitely by dribbling out header bytes, and
	// http.Server has no default. It matters more here than it looks -- the
	// pprof surface is the one that hands out goroutine dumps and profiles,
	// so the cheapest denial of service against it is also the one that ties
	// up the handler you would use to diagnose the denial of service.
	srv := &http.Server{Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	errCh := make(chan error, 1)
	go func() { errCh <- srv.Serve(lis) }()

	select {
	case <-ctx.Done():
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		return srv.Shutdown(shutdownCtx)
	case err := <-errCh:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	}
}
