package observability

import "context"

// WithBaseAttrs returns a Tracer that merges `base` into every span's attrs
// before delegating to tr, so a replayed trace names WHICH code and config
// produced it -- the operational-determinism requirement (production
// output is F(code, config, state, inputs)) applied to the tracing surface.
// The composition root (cmd/<SERVICE>) attaches the build revision + config
// digest here, once, rather than threading them through every StartSpan
// call site.
//
// Per-span attrs win on key collision -- `base` only fills in identity keys
// no call site already sets.
//
// Returns tr UNCHANGED when tr is the noop Tracer or base is empty: a noop
// span never inspects its attrs, so merging into it would add pure
// allocation cost to the default no-tracing deployment for zero observable
// benefit.
func WithBaseAttrs(tr Tracer, base map[string]string) Tracer {
	if len(base) == 0 {
		return tr
	}
	if _, isNoop := tr.(noopTracer); isNoop {
		return tr
	}
	cp := make(map[string]string, len(base))
	for k, v := range base {
		cp[k] = v
	}
	return &baseAttrsTracer{tracer: tr, base: cp}
}

type baseAttrsTracer struct {
	tracer Tracer
	base   map[string]string
}

func (b *baseAttrsTracer) StartSpan(ctx context.Context, name string, attrs map[string]string) (context.Context, Span) {
	merged := make(map[string]string, len(b.base)+len(attrs))
	for k, v := range b.base {
		merged[k] = v
	}
	for k, v := range attrs {
		merged[k] = v
	}
	return b.tracer.StartSpan(ctx, name, merged)
}
