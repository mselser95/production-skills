# Gate runtime baseline

**Why this exists.** The pre-commit hook runs `make check-fast` on every commit.
A gate people wait for is a gate people bypass — `--no-verify` costs nothing and
leaves no trace — so the runtime is a property worth watching, not a detail. This
file is the number to compare against when someone says "the hook got slow".

It is a **SIGNAL, not a gate**: nothing fails on a regression here. A wall-clock
measurement on one laptop cannot be a pass/fail threshold, and pretending
otherwise produces a check that goes red when the machine is busy.

## Measured 2026-08-29

Apple Silicon (arm64), macOS 25.5, GNU bash 5.3, shellcheck 0.11.0, actionlint
from `go install`. Three consecutive runs each, warm filesystem cache, nothing
else heavy running.

| target | runs (s) | what it does |
|---|---|---|
| `actionlint` | 0.2 · 0.1 · 0.1 | validate the workflow files, locally — CI cannot validate its own |
| `lint` | 4.7 · 4.5 · 4.4 | shellcheck over 36 unique scripts of 62 (deduped by content) |
| `gates` | 5.9 · 5.8 · 5.6 | skills-static, policy-coverage, row-vacuity-sweep, check-registries, probe-wiring ×2 |
| **`check-fast`** | **10.4 · 10.1 · 10.3** | **what the pre-commit hook runs** |
| `selftests` | 17.9 | the verifiers-of-verifiers, globbed (grew with the suite) |
| `invariants` | 12.1 | the 3 ratified invariants; inv-002 reinstalls the TCB four times |

`verify` = `check-fast` + `selftests` + `invariants` + `tcb` + `mutation`, so
roughly a minute.

**`evidence` is the slow one, deliberately and with a known duplication.** It
re-runs every gate from scratch — a record assembled from another step's exit
codes attests to what the Makefile says ran, not to what ran — and the mutation
trend re-executes all ten selftests to COUNT what they demonstrate, which
`selftests` has already executed once. That duplication is ~18s of its total. It
is kept because collapsing the two would make one gate's evidence a claim about
the other's run, and the record exists precisely to not do that.

**Measured 2026-08-31: 62s.** It got a row here after a 2-minute shell timed out
— which was NOT `evidence` alone, but `evidence` running fourth in a chain of
gates inside one command. Worth stating precisely, because "the evidence target
takes over two minutes" would be a number someone plans around and it is wrong. `evidence` re-runs
the gates and writes the record, so it is `check-fast` plus `selftests` plus the
TCB check again.

## The one number that matters

**`check-fast` at ~10s is the budget.** It is what stands between a commit and
the tree, and it was 35s before `lint` was deduped by content — install.sh
mirrors the shared probes into all nine skills byte-identically, so shellcheck
was linting ten copies of `verify-standard.sh` and returning the same verdict
ten times. Content-dedup took `lint` from 29.8s to 4.5s with identical coverage
(same distinct programs, proven by the gate still going red on a planted error).

If this creeps past ~20s, look for the same shape before adding a `SKIP=` escape
hatch: work being done N times that only needs doing once.

## Re-measuring

```
for t in actionlint lint gates selftests check-fast; do
  time make --no-print-directory $t >/dev/null
done
```

Numbers from a different machine are not comparable to these and should not
replace them; add a row instead, with the machine named.
