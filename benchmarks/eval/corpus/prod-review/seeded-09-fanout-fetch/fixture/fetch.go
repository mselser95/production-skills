// Package fanout queries several backends at once and merges their answers.
package fanout

import (
	"context"
	"errors"
	"sort"
	"sync"
)

// Item is one search hit.
type Item struct {
	ID    string
	Score int
}

// Backend answers one query. It should stop when ctx is done.
type Backend func(ctx context.Context, query string) ([]Item, error)

// Fetcher fans a query out to every backend.
type Fetcher struct {
	backends []Backend
	attempts int
}

// New returns a Fetcher that tries each backend up to attempts times.
func New(attempts int, backends ...Backend) *Fetcher {
	if attempts < 1 {
		attempts = 1
	}
	return &Fetcher{backends: backends, attempts: attempts}
}

// Fetch queries all backends concurrently and returns the merged hits, best
// score first. A backend that fails is skipped; the call fails only when
// every backend failed.
func (f *Fetcher) Fetch(ctx context.Context, query string) ([]Item, error) {
	results := make([][]Item, len(f.backends))
	errs := make([]error, len(f.backends))
	var wg sync.WaitGroup
	for i, b := range f.backends {
		wg.Add(1)
		go func(i int, b Backend) {
			defer wg.Done()
			results[i], errs[i] = f.call(ctx, b, query)
		}(i, b)
	}
	wg.Wait()

	best := map[string]int{}
	failed := 0
	for i := range f.backends {
		if errs[i] != nil {
			failed++
			continue
		}
		for _, it := range results[i] {
			if s, ok := best[it.ID]; !ok || it.Score > s {
				best[it.ID] = it.Score
			}
		}
	}
	if len(f.backends) > 0 && failed == len(f.backends) {
		return nil, errors.Join(errs...)
	}
	out := make([]Item, 0, len(best))
	for id, s := range best {
		out = append(out, Item{ID: id, Score: s})
	}
	sort.Slice(out, func(a, b int) bool {
		if out[a].Score != out[b].Score {
			return out[a].Score > out[b].Score
		}
		return out[a].ID < out[b].ID
	})
	return out, nil
}

func (f *Fetcher) call(ctx context.Context, b Backend, query string) ([]Item, error) {
	var err error
	for i := 0; i < f.attempts; i++ {
		if cerr := ctx.Err(); cerr != nil {
			return nil, cerr
		}
		var items []Item
		if items, err = b(ctx, query); err == nil {
			return items, nil
		}
	}
	return nil, err
}
