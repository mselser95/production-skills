# clean-05-quota-meter (dev) - CLEAN, no defect
Change (modifies `meter.go` only, adds no file): `Charge` first drops the tenant's entries older than the rolling window, then
admits `n` only if `n <= limit-used`; new exported `Remaining(tenant)` reads the units left; new unexported `prune` does the expiry.
Looks suspicious but is correct: `n > m.limit-used` is used instead of `used+n > m.limit` because `used <= limit` always (every
kept entry was admitted under the limit, and pruned entries are deleted for good), so the subtraction cannot overflow while the sum
could for a huge `n`; the window is closed on purpose (`now.Sub(at) > window` expires, so an entry exactly one window old still
counts) and the comment says so; `kept := m.used[tenant][:0]` filters in place and is safe because the write index never passes the read index.
Checked with scratch tests (not in the fixture): boundary at exactly window and window+1ns, `MaxInt64` limit and charges, limit 0,
`MaxInt64` window, 300 randomized runs against a `math/big` model including a clock that steps backwards, `Remaining` never negative,
64 goroutines under `-race` with `-count=3`; mutating `>` to `>=` or the subtraction to `used+n` turns them RED. No bug found in the draft.
Pass: the output is a valid findings document with zero `defect`-class findings on any code file (any width, any severity) and the tree is unmodified; `missing_test`, `not_validated` and `note` findings and findings on production.yaml/.prod/ are tolerated. `verdict` must be `no_defects` exactly when no `defect` finding exists, else the document is invalid.
False positive looks like: flagging a possible overflow in the limit check or the sum, the inclusive window boundary as an off-by-one,
the in-place `[:0]` filter, `Remaining` mutating state under the lock, or the clock being read once per call.
