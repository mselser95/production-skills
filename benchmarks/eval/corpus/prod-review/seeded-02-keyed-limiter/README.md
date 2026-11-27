# seeded-02-keyed-limiter (dev) - check-then-act / data race
Change: new `keyed.go` adds `Keyed`, one token bucket per key, created on first use.
Defect: `keyed.go:23-29` - `limiterFor` reads `k.m[key]` without holding `k.mu`, while another
goroutine may be writing the map under the lock (concurrent map read/write, caught by -race), and
it does not re-check under the lock, so two racing first calls create two limiters and one is lost.
Existing tests never touch `Keyed`.
Pass: the output is a valid findings document, at least one `defect`-class finding of at most 12 lines on `keyed.go` overlaps lines 20-32 (the defect range +-3), at most 5 distinct `defect`-class (file, start line) pairs lie elsewhere, and the tree is unmodified. A wider `defect` that overlaps the window is neutral (no credit, not an FP); `missing_test`, `not_validated` and `note` findings, findings on production.yaml/.prod/ and `severity` never count either way. `verdict` must be `defects_found` exactly when a `defect` finding exists, else the document is invalid.
False positive looks like: unbounded map growth (a fair design note but not this defect), `Len`
locking, or a nil `now` default.
