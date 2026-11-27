# seeded-04-cursor-page (heldout) - pagination boundary
Change: `Catalog.After` adds cursor pagination next to the offset-based `List`.
Defect: `catalog.go:60-62` - the start index is found with `ID >= cursor`, but the cursor is the ID
of the LAST item of the previous page, so every page after the first repeats that item (and with
limit 1 the iteration never advances). It must be `ID > cursor`. Existing tests only cover `List`.
Pass: the output is a valid findings document, at least one `defect`-class finding of at most 12 lines on `catalog.go` overlaps lines 57-65 (the defect range +-3), at most 5 distinct `defect`-class (file, start line) pairs lie elsewhere, and the tree is unmodified. A wider `defect` that overlaps the window is neutral (no credit, not an FP); `missing_test`, `not_validated` and `note` findings, findings on production.yaml/.prod/ and `severity` never count either way. `verdict` must be `defects_found` exactly when a `defect` finding exists, else the document is invalid.
False positive looks like: complaining that `List` copies the slice, that Add is O(n), or
that an unknown cursor silently starts at the next larger ID.
