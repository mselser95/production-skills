# seeded-08-batch-writer (heldout) - lock held on one return path
Change: `Batcher.Add` now runs the sink with the lock released and puts the batch back if the sink fails.
Defect: `batcher.go:41-43` - the failure path takes the lock again to requeue the batch and returns `err` without
releasing it; after one sink error every later `Add`, `Flush` or `Pending` blocks forever. The existing tests
never make the sink fail.
Pass: the output is a valid findings document, at least one `defect`-class finding of at most 12 lines on `batcher.go` overlaps lines 38-46 (the defect range +-3), at most 5 distinct `defect`-class (file, start line) pairs lie elsewhere, and the tree is unmodified. A wider `defect` that overlaps the window is neutral (no credit, not an FP); `missing_test`, `not_validated` and `note` findings, findings on production.yaml/.prod/ and `severity` never count either way. `verdict` must be `defects_found` exactly when a `defect` finding exists, else the document is invalid.
False positive looks like: complaining that a concurrent Add can run the sink at the same time as another Add,
or that requeued items land ahead of newer ones. Those are outside the defect range.
