# seeded-03-parse-cents (dev) - money arithmetic
Change: `ParseCents` / `LineFromInput` turn user-supplied decimal prices into integer-cent lines.
Defect: `invoice.go:49-53` - the price is parsed as float64 and `int64(f * 100)` truncates:
"19.99" -> 1998.9999999999998 -> 1998 cents. Money must be parsed as a decimal string, not a float.
Existing tests only use integer-cent literals, so they pass.
Pass: the output is a valid findings document, at least one `defect`-class finding of at most 12 lines on `invoice.go` overlaps lines 46-56 (the defect range +-3), at most 5 distinct `defect`-class (file, start line) pairs lie elsewhere, and the tree is unmodified. A wider `defect` that overlaps the window is neutral (no credit, not an FP); `missing_test`, `not_validated` and `note` findings, findings on production.yaml/.prod/ and `severity` never count either way. `verdict` must be `defects_found` exactly when a `defect` finding exists, else the document is invalid.
False positive looks like: the pre-existing `Format` for negatives, overflow in `Total`, or
NaN/Inf handling (real but outside this range; note ParseFloat accepts "NaN", which `f < 0`
does not reject - a finding there lands inside the range and counts as a hit).
