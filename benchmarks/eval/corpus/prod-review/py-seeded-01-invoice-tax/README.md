# py-seeded-01-invoice-tax (dev) - tax rounded with the wrong rounding mode
Change: `invoicing/lines.py` gains `line_tax` and `invoice_total`: per-line sales tax at a rate, summed with the net.
Defect: `invoicing/lines.py:35-35` - `quantize(CENT)` with no `rounding=` uses the decimal context default, ROUND_HALF_EVEN, while the
module's own `to_cents` (money.py) rounds half-up as the invoice rules require. A tax that lands on a half cent is rounded to the
even cent: 2.50 at 5% is 0.125, which becomes 0.12 instead of 0.13, and `invoice_total` is a cent short. Nothing raises; the
existing tests never call the new functions, and only compare `to_cents` itself.
Tests: `python3 -m unittest discover -s tests -v` from the repo root (standard library only, Python >= 3.11); they pass before and after the change and never touch the changed code.
Pass: the output is a valid findings document, at least one `defect`-class finding of at most 12 lines on `invoicing/lines.py` overlaps lines 32-38 (the defect range +-3), at most 5 distinct `defect`-class (file, start line) pairs lie elsewhere, and the tree is unmodified. A wider `defect` that overlaps the window is neutral (no credit, not an FP); `missing_test`, `not_validated` and `note` findings, findings on production.yaml/.prod/ and `severity` never count either way. `verdict` must be `defects_found` exactly when a `defect` finding exists, else the document is invalid.
False positive looks like: complaining about the `Sequence` being iterated twice, rounding per line instead of on the sum, or the
zero rate being accepted. Those are outside the defect range.
