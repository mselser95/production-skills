# clean-07-audit-log (dev) - CLEAN, no defect
Change (modifies `log.go` and `file.go` only): `Log.Close` now also closes the destination when it is an `io.Closer`, after the flush;
`OpenFile` stats the file it opened, refuses a non-regular file, and releases the file through a deferred close when that fails.
Looks suspicious but is correct: two errors are deliberately not reported, and both have the primary error returned in full.
In `Close`, a close error after a failed flush is dropped because the flush error is the one returned (a clean flush reports the
close error); the destination is closed on every path, once, and a second `Close` is a no-op under the mutex. In `OpenFile`,
`_ = f.Close()` runs in a defer keyed on the named result `err`, so every failing return releases the file, and the success path
hands the open file to the `Log`, which now closes it.
Checked with scratch tests (not in the fixture): write failure plus close failure returns the write error and closes once,
close-only failure is reported, non-closer destination, double close, 64 goroutines appending/flushing while closing under `-race`
with contiguous sequence numbers and exactly one destination close, 2000 failed opens of `/dev/null` and 3000 open/append/close
cycles with no descriptor exhaustion, directory and missing-parent paths, goroutine counts before and after, `-count=5`.
Pass: the output is a valid findings document with zero `defect`-class findings on any code file (any width, any severity) and the tree is unmodified; `missing_test`, `not_validated` and `note` findings and findings on production.yaml/.prod/ are tolerated. `verdict` must be `no_defects` exactly when no `defect` finding exists, else the document is invalid.
False positive looks like: flagging `_ = f.Close()` or the dropped close error in `Close` as a swallowed error, the defer
ordering in `OpenFile`, the `err`/`f` redeclaration against the named result, or rejecting non-regular files.
