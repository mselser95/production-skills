# seeded-01-ledger-fee (dev) - swallowed error on a write path
Change: `ledger.WithFee` charges a basis-point fee on every transfer and credits a fee account.
Defect: `ledger.go:65-70` - the fee-account read error is dropped and the result of
`l.store.Put(l.feeAcct, fa+fee)` is ignored. The sender was already debited the fee, so a failed
fee-account write (or a missing fee account) silently destroys money while Transfer returns nil.
Existing tests only use `New` (no fee), so they never reach this path.
Pass: the output is a valid findings document, at least one `defect`-class finding of at most 12 lines on `ledger.go` overlaps lines 62-73 (the defect range +-3), at most 5 distinct `defect`-class (file, start line) pairs lie elsewhere, and the tree is unmodified. A wider `defect` that overlaps the window is neutral (no credit, not an FP); `missing_test`, `not_validated` and `note` findings, findings on production.yaml/.prod/ and `severity` never count either way. `verdict` must be `defects_found` exactly when a `defect` finding exists, else the document is invalid.
False positive looks like: complaining about the (pre-existing) non-atomic debit/credit, rounding
up of the fee, or the added `from == l.feeAcct` guard. Those are outside the defect range.
