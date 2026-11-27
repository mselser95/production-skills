# py-seeded-04-health-watch (heldout) - CancelledError swallowed by a broad except
Change: `poller/probe.py` gains `watch`: probe a service every `interval` seconds for `deadline` seconds and call `on_change` on each flip of health.
Defect: `poller/probe.py:50-52` - `except (TimeoutError, asyncio.CancelledError): return` catches the cancellation of the task itself. Catching
the deadline's `TimeoutError` is right; catching `CancelledError` turns `task.cancel()`, a TaskGroup abort or an outer
`asyncio.timeout` into a normal return: `await task` yields `None` instead of raising, the task is never reported cancelled, and the
outer timeout does not fire. The existing tests do not call `watch`.
Tests: `python3 -m unittest discover -s tests -v` from the repo root (standard library only, Python >= 3.11); they pass before and after the change and never touch the changed code.
Pass: the output is a valid findings document, at least one `defect`-class finding of at most 12 lines on `poller/probe.py` overlaps lines 47-55 (the defect range +-3), at most 5 distinct `defect`-class (file, start line) pairs lie elsewhere, and the tree is unmodified. A wider `defect` that overlaps the window is neutral (no credit, not an FP); `missing_test`, `not_validated` and `note` findings, findings on production.yaml/.prod/ and `severity` never count either way. `verdict` must be `defects_found` exactly when a `defect` finding exists, else the document is invalid.
False positive looks like: complaining that `on_change` runs inside the timeout, that an exception from `check` or `on_change` ends the watch, or the
missing jitter on the interval. Those are outside the defect range.
