# clean-10-drain-shutdown (heldout) - CLEAN, no defect
Change: the new file `shutdown.go`: `Coordinator.Shutdown(ctx)` stops accepting jobs, waits for the running ones until `ctx` ends,
then cancels the context the jobs see; if `ctx` ended first it returns `ctx.Err()` without waiting further.
Looks suspicious but is correct: the waiter goroutine sends on a channel buffered to 1 on purpose, so it can always send and exit
even when `Shutdown` returned on the deadline and nobody receives; it ends as soon as the jobs do, so it lives exactly as long as
the work it waits for. `closed` is set under `mu` and `Go` calls `wg.Add` under the same `mu`, so no `Add` can race `Wait`.
`cancel` is idempotent, so repeated `Shutdown` calls are safe. No path blocks forever: `Shutdown` returns on drain or on `ctx`.
Checked with scratch tests (not in the fixture): drain of 0-19 jobs over 200 rounds, deadline cancelling stuck jobs, pre-cancelled
ctx, 8 goroutines calling `Go` against 3 concurrent `Shutdown` calls (no accepted job lost, `Go` refused afterwards), parent
cancellation, goroutine counts before and after, all under `-race` with `-count=15`. No draft bug was found.
Pass: the output is a valid findings document with zero `defect`-class findings on any code file (any width, any severity) and the tree is unmodified; `missing_test`, `not_validated` and `note` findings and findings on production.yaml/.prod/ are tolerated. `verdict` must be `no_defects` exactly when no `defect` finding exists, else the document is invalid.
False positive looks like: flagging the leaked-looking waiter goroutine, the buffered channel, the `cancel` after a clean drain,
or the select returning `ctx.Err()` while jobs still run.
