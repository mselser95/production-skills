# seeded-10-bulk-import (heldout) - partial failure reported as success
Change: `Import` now keeps going when a row cannot be stored, skips blank lines and accepts rows up to 1 MiB.
Defect: `importer.go:46-48` - a failed `Put` hits `continue`: the error is not returned, not counted in
`Rejected`, and the row is absent from `Stored`, so an import where rows failed to store returns `nil` and a
`Result` indistinguishable from a clean run of fewer rows. The existing tests never make the store fail.
Pass: the output is a valid findings document, at least one `defect`-class finding of at most 12 lines on `importer.go` overlaps lines 43-51 (the defect range +-3), at most 5 distinct `defect`-class (file, start line) pairs lie elsewhere, and the tree is unmodified. A wider `defect` that overlaps the window is neutral (no credit, not an FP); `missing_test`, `not_validated` and `note` findings, findings on production.yaml/.prod/ and `severity` never count either way. `verdict` must be `defects_found` exactly when a `defect` finding exists, else the document is invalid.
False positive looks like: complaining that blank lines are skipped without being counted, that the context
check runs per row, or that the 1 MiB cap is arbitrary. Those are outside the defect range.
