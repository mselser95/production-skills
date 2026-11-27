# py-clean-01-command-runner (dev) - CLEAN, no defect
Change: `cmdrun/runner.py` gains `Completed` and `run_capture`: feed bytes to a command (no shell) and return its code, stdout and stderr; a
timeout or interrupt kills the child and propagates.
Looks suspicious but is correct: the broad `except BaseException` only kills the child and re-raises, so nothing is swallowed; the
`with Popen` closes the pipes and reaps the child after the kill; `communicate(data, timeout=)` feeds stdin and drains both pipes
together, so a large input or large outputs cannot deadlock, and a child that never reads stdin (or closes it) does not raise
BrokenPipeError; the argument list reaches the child unchanged, so shell metacharacters are inert; `errors="replace"` makes undecodable bytes
U+FFFD instead of an exception. It mirrors `subprocess.run`'s own handler (kill, re-raise, let `__exit__` wait).
Checked with scratch tests (not in the fixture): 17 cases on 3.15 and 3.14 - stdin round trip, 5 MB in with 3 MB on each output
stream, child ignoring a 5-20 MB stdin, timeout kills and reaps the child and raises TimeoutExpired (pid checked), timeout 0 and negative,
a mocked and a real SIGINT during the wait (child gone, KeyboardInterrupt propagates), undecodable bytes, empty argv, missing binary,
metacharacters, no descriptor growth over 55 runs, 16 threads, a child killed by a signal (returncode -9).
Tests: `python3 -m unittest discover -s tests -v` from the repo root (standard library only, Python >= 3.11); they pass before and after the change and never touch the changed code.
Pass: the output is a valid findings document with zero `defect`-class findings on any code file (any width, any severity) and the tree is unmodified; `missing_test`, `not_validated` and `note` findings and findings on production.yaml/.prod/ are tolerated. `verdict` must be `no_defects` exactly when no `defect` finding exists, else the document is invalid.
False positive looks like: flagging the broad `except BaseException`, the missing `check=`, `text` decoding left lossy, the ignored
pid after `kill()`, or a possible zombie for an instant after a real Ctrl-C (the standard library's `run` has the same window).
