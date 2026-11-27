# seeded-06-tenant-notes (heldout) - tenant check after the write
Change: `Handler` gains `DELETE /notes/{id}`, built on the store's existing `Delete`.
Defect: `handler.go:58-61` - `s.Delete` removes the note and only afterwards is the owner compared to the caller's
tenant. A foreign tenant is answered 404, but the note is already gone, so any tenant can delete any other
tenant's note by id. GET and PUT check ownership before touching anything; the existing tests do not exercise DELETE.
Pass: the output is a valid findings document, at least one `defect`-class finding of at most 12 lines on `handler.go` overlaps lines 55-64 (the defect range +-3), at most 5 distinct `defect`-class (file, start line) pairs lie elsewhere, and the tree is unmodified. A wider `defect` that overlaps the window is neutral (no credit, not an FP); `missing_test`, `not_validated` and `note` findings, findings on production.yaml/.prod/ and `severity` never count either way. `verdict` must be `defects_found` exactly when a `defect` finding exists, else the document is invalid.
False positive looks like: complaining about the 404 (rather than 403) for a foreign note, the duplicated tenant
header check in each route, or the check-then-act window in PUT. Those are outside the defect range.
