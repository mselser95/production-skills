# seeded-09-fanout-fetch (dev) - cancellation not honoured
Change: `Fetcher.WithBackoff` makes a failed backend wait (doubling, capped at 30 s) before its next retry.
Defect: `fetch.go:102-104` - the wait is a plain `time.Sleep`, so a cancelled `ctx` is not seen until the sleep
ends; `Fetch` (which joins every backend goroutine) returns seconds after the caller cancelled. It should wait
with `select` on a timer and `ctx.Done()`. The existing tests never combine a backoff with a cancel; a scratch
test (backoff 2 s, cancel at 50 ms) sees `Fetch` return after 2.005 s.
Pass: the output is a valid findings document, at least one `defect`-class finding of at most 12 lines on `fetch.go` overlaps lines 99-107 (the defect range +-3), at most 5 distinct `defect`-class (file, start line) pairs lie elsewhere, and the tree is unmodified. A wider `defect` that overlaps the window is neutral (no credit, not an FP); `missing_test`, `not_validated` and `note` findings, findings on production.yaml/.prod/ and `severity` never count either way. `verdict` must be `defects_found` exactly when a `defect` finding exists, else the document is invalid.
False positive looks like: complaining that `WithBackoff` mutates the receiver, that there is no jitter, or that
the 30 s cap is hard-coded. Those are outside the defect range.
