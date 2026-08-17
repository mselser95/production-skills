package observability

import (
	"context"
	"sync"
)

// Recording is a test-double Tracer that records every span started, for
// assertions in other packages' tests without depending on a real tracing
// backend or on log output scraping. Safe for concurrent use.
type Recording struct {
	mu    sync.Mutex
	Spans []RecordedSpan
}

// RecordedSpan is one completed span as Recording observed it.
type RecordedSpan struct {
	Name  string
	Attrs map[string]string
	Err   error
}

// NewRecording returns a ready-to-use Recording tracer.
func NewRecording() *Recording { return &Recording{} }

func (r *Recording) StartSpan(ctx context.Context, name string, attrs map[string]string) (context.Context, Span) {
	cp := make(map[string]string, len(attrs))
	for k, v := range attrs {
		cp[k] = v
	}
	return ctx, &recordingSpan{rec: r, name: name, attrs: cp}
}

type recordingSpan struct {
	rec   *Recording
	name  string
	attrs map[string]string
	err   error
}

func (s *recordingSpan) RecordError(err error) {
	if err == nil {
		return
	}
	s.err = err
}

func (s *recordingSpan) End() {
	s.rec.mu.Lock()
	defer s.rec.mu.Unlock()
	s.rec.Spans = append(s.rec.Spans, RecordedSpan{Name: s.name, Attrs: s.attrs, Err: s.err})
}

// Named returns every recorded span with the given name, in order.
func (r *Recording) Named(name string) []RecordedSpan {
	r.mu.Lock()
	defer r.mu.Unlock()
	var out []RecordedSpan
	for _, s := range r.Spans {
		if s.Name == name {
			out = append(out, s)
		}
	}
	return out
}
