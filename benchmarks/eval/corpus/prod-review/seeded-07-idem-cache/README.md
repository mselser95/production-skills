# seeded-07-idem-cache (heldout) - unit confusion in a lifetime
Change: `Cache.PutFor` stores a response for a caller-given lifetime in milliseconds; `Sweep` drops expired entries.
Defect: `cache.go:41` - the `ttlMillis` argument is converted with `time.Second`, so an entry stored for 500 ms
lives 500 s. An idempotency cache that outlives its window replays stale responses for a retried key. The existing
tests only use `Put` with the default ttl.
Pass: the output is a valid findings document, at least one `defect`-class finding of at most 12 lines on `cache.go` overlaps lines 38-44 (the defect range +-3), at most 5 distinct `defect`-class (file, start line) pairs lie elsewhere, and the tree is unmodified. A wider `defect` that overlaps the window is neutral (no credit, not an FP); `missing_test`, `not_validated` and `note` findings, findings on production.yaml/.prod/ and `severity` never count either way. `verdict` must be `defects_found` exactly when a `defect` finding exists, else the document is invalid.
False positive looks like: complaining about `Sweep` holding the lock while it ranges, `Get` returning the stored
slice without a copy, or the expiry boundary (`!Before`). Those are outside the defect range.
