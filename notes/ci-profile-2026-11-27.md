# Why the CI `gates` job takes 17 minutes (2026-11-27)

Rule (owner, 2026-11-27): checks in this repo finish in UNDER ONE MINUTE, and nothing re-runs
unless its inputs changed — cache results by content hash. Measured on PR #18 (run 46043034240), which already
carries the faster hygiene gate:

| Step | Seconds |
|---|---|
| `evidence record (dimension 11)` | 592 |
| `make check-fast` (the step also runs `make selftests`) | 334 |
| `eval harness (hermetic)` | 50 |
| `secret scanning (blocking)` | 25 |
| `probe selftests` | 18 |
| everything else | 24 |
| total | 1043 |

The hygiene gate (one `sed` per line → one per file) fixed the LOCAL pre-commit under load
(2–30 min → 23 s). It was never the main cost in CI.

## Causes (read-only profiling in a Linux container, partial)

1. **`scripts/evidence-record.sh` re-runs what the job already ran.** Its `GATES` array has 17
   entries; 15 of them (`make actionlint`, `make lint`, skills-static, agents-budget,
   policy-coverage, row-vacuity-sweep, check-registries, gate-hygiene-fitness, probe-wiring ×2,
   template-digest, gap-report-consistency, template-workflow-pins, `make selftests`,
   `install.sh --verify`) executed earlier in the same job. Only `scripts/mutation-baseline.sh`
   and `make invariants` are new there.
2. **Every selftest suite runs 3 to 4 times per CI run:** `make selftests` in the check-fast
   step; `scripts/mutation-baseline.sh` (runs every suite to count cases) inside `make evidence`;
   `make selftests` again inside `make evidence`; and several suites a 4th time as named steps.
3. **`make lint` is serial shellcheck** over 174 tracked `.sh` files, 6.15 MB (`xargs` without
   `-P`): 135 s of the 166 s that `check-fast` takes in the container. The files are deduped by
   sha256 already; the cost is the one thread.
4. The `gates` recipe itself is about 31 s in total (skills-static 14, hygiene 9, row-vacuity 4,
   the rest under 2 each).

## Direction (not started — touches Makefile, pr.yaml and evidence-record.sh, which PR #17 edits)

- The evidence record should ATTEST results produced once in the job, not re-execute the gates:
  run each gate once, capture exit code + output digest, and have `evidence-record.sh` consume
  those. Its own guard ("every gate in `make gates` must be in GATES") must keep its meaning.
- Count selftest cases from the single selftest pass instead of a second full pass in
  `mutation-baseline.sh`.
- Parallelise shellcheck (`xargs -P`), keeping the "refuses to report clean over zero files"
  guard.
- Then split what remains across jobs only if a single job still exceeds 2 minutes.

## Not measured

Per-suite selftest times; `make evidence` attributed per sub-command; execve counts; whether the
selftests can run concurrently (shared temp names, writes into the repo tree); the pinned
shellcheck 0.10.0 on x86_64 (the container had 0.9.0 on aarch64 with 16 cores; the runner has
about 4 vCPU, so absolute times in CI are higher).

## Owner decision, 2026-11-27: under one minute, and cache by content

"Why run tests when the code did not change? Cache all of it; if the template or the sha
changes, then yes." Answer: there was no reason — the repo simply had neither path filters nor a
cache. Plan:

1. `scripts/gate-run-cached.sh` (in progress, branch `ci/gate-cache`): a content-addressed
   wrapper. Key = declared input files' content + the gate command + tool versions + OS + the
   wrapper's own hash. Only PASS is cached; inputs that match nothing are an error; `verify`
   mode re-runs on a hit and reports a `CACHE LIE` when a cached PASS now fails (an undeclared
   input).
2. Wire every gate and selftest through it with declared inputs (after PR #17 lands: it edits
   the same files). A selftest's inputs are its own script, the probe it tests and the files
   that probe reads.
3. The evidence record attests results (executed vs attested-from-cache), it does not re-run.
4. CI restores the cache directory (`actions/cache`, keyed on the tree); pull requests read it;
   the default branch runs in `verify` or uncached mode so the truth is recomputed once.
5. Parallelise what still has to run (shellcheck `xargs -P`).
A cache is a gate that passes without running, so it carries the same mutation proof as any
other gate here.
