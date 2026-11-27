# clean-09-chunk-upload (heldout) - CLEAN, no defect
Change (modifies `upload.go` only): the chunked-upload `Assembler` now accepts a total that is not a multiple of the chunk size (the last chunk is
shorter), an empty upload (one empty chunk), and gains `Received()`, the count of distinct bytes stored.
Looks suspicious but is correct: the chunk count is `total/chunk` plus one only when there is a remainder or total is 0, computed without
`total+chunk-1`, so it cannot overflow near `MaxInt64`; `wantLen` is `min(chunk, total-idx*chunk)` and `idx` is range-checked first, so the
product never exceeds `total` and the length is never negative; a resent chunk is still refused with `ErrDuplicate` before it is stored, so
`Received` never counts a byte twice; a zero-length chunk for a non-empty upload is `ErrIndex`, and for an empty upload it is the one valid
chunk; `Bytes` appends each part whole, so the short last chunk is neither padded nor truncated; `ErrTotal` stays reachable and now means only a negative total (a total that is not a multiple of the chunk size is valid).
Checked with scratch tests (not in the fixture): every total 0-60 against every chunk size 1-70 with shuffled arrival, wrong-length (one
byte short or long) and duplicate on every chunk, out-of-range indexes including -1 and `MaxInt`, `Received == total`, reassembled bytes equal to
the source, `MaxInt64` totals, and 8 goroutines adding the same chunks under `-race` with `-count=3` (each chunk accepted exactly once).
Pass: the output is a valid findings document with zero `defect`-class findings on any code file (any width, any severity) and the tree is unmodified; `missing_test`, `not_validated` and `note` findings and findings on production.yaml/.prod/ are tolerated. `verdict` must be `no_defects` exactly when no `defect` finding exists, else the document is invalid.
False positive looks like: claiming the last partial chunk loses or pads bytes, that `Received` double counts a duplicate, that an
empty upload needs zero chunks, that `idx*chunk` can overflow.
