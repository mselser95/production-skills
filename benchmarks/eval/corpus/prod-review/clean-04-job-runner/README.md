# clean-04-job-runner (heldout) - CLEAN, no defect
Change: the new file `runall.go`: `RunAll` runs jobs on up to `workers` goroutines; the first error cancels a derived context and is the
result; if the caller's context ends first, `RunAll` returns `ctx.Err()`.
Looks suspicious but is correct: `defer cancel()` runs after `wg.Wait()` and only releases the derived context;
`first` is written inside `once.Do` and read after `Wait`, so there is no race; a job's own `context.Canceled`
cannot hide the root error because `once.Do` blocks until the first error is recorded; job indexes come from
one atomic counter so each job runs once; the pool has no producer goroutine, so nothing can block on exit;
`done < len(jobs)` distinguishes a cancel that cut the run short from one that arrived after the last job.
Checked with scratch tests (not in the fixture): each job exactly once for 1-1000 workers and 0-500 jobs,
first error wins across 300 schedules, parent cancel mid-run, pre-cancelled context, cancel after completion,
zero or negative workers, goroutine counts before and after, all under `-race` with `-count=30`.
Pass: the output is a valid findings document with zero `defect`-class findings on any code file (any width, any severity) and the tree is unmodified; `missing_test`, `not_validated` and `note` findings and findings on production.yaml/.prod/ are tolerated. `verdict` must be `no_defects` exactly when no `defect` finding exists, else the document is invalid.
False positive looks like: flagging `defer cancel()` ordering, the shared `first` variable, a job started just
as the context ends, or the unused loop variable `w`.
