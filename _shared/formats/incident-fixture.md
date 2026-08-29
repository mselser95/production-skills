# Format: incident fixture + candidate invariant package

What `prod-incident` produces when closing an incident. The fixture corpus is
the least gameable evidence in the framework — its oracle is reality — so its
hygiene matters more than its size.

## Directory

```
<PROD_REGRESSIONS_DIR>/          # default: regressions/
  <yyyy-mm-dd>-<slug>/
    fixture.yaml          # metadata
    events.json           # MINIMIZED input sequence (10–50 events, hand-blessed)
    invariants.txt        # which invariant ids must hold when replaying
```

Rules:

- **Minimized, not raw.** Minimization is part of incident close-out. A raw
  production capture is not a fixture; it is fixture rot on a timer.
- **Assert invariants, never golden state.** `expected.json` snapshots break
  on every intended behavior change and get regenerated wholesale — at which
  point the suite verifies that the code does what the code does. Replay
  asserts the named invariants held at every transition, nothing more.
- `fixture.yaml` records `schema_version:`; a schema migration must either
  upcast the fixture or re-express it, in a reviewed change.

## fixture.yaml

```yaml
incident: <ticket/ref>
date: <date>
services: [<service>]
schema_version: <n>
summary: <one sentence: what production actually did>
minimized_from: <original event count> -> <fixture event count>
```

## Candidate invariant package (goes to ratification, not to code)

```yaml
candidate_invariant:
  statement: <precise, falsifiable text>
  evidence_for:            # both directions are MANDATORY
    passing_runs: <N runs on current code>
  evidence_against:
    violation_trace: <the concrete mutant/fault/sequence that violates it>
  contradiction_check:     # vs declared capability contracts — a candidate that
    result: clean|CONFLICT # contradicts a declared clause (e.g. "exactly once"
    detail: <clause>       # vs may_be_duplicate:true) is rejected before review
  prod_soak:               # shadow counter results, if available pre-ratification
    counter: <name>
    window: <days>
    firings: <n>

# The two fields the probe SCORES, and which this spec did not describe until
# 2026-08-28 — measured: the template's own packages carried non_vacuity_check
# and not `test:`, so verify-standard.sh's `ratification-citations` row could
# never pass on a freshly scaffolded repo.
test:
  function: <the test function this invariant is asserted by>
non_vacuity_check:       # what the probe EXECUTES to prove the test is not decoration
  file: <path>           # the mutation is applied here...
  expect_red: <TestName> # ...and THIS test must go RED, or the invariant is
  find: <exact text>     # satisfied by code that asserts nothing
  replace: <exact text>
```

**`test.function` and `non_vacuity_check.expect_red` name the SAME test, in two
independently-written places, and that redundancy is the whole point.**
`expect_red` is what the probe executes; `test.function` is what the package
claims. A single field cannot detect a drift, because there is nothing to
compare it against — and the drift is real: a package in another repo cited
`TestFailedFetchNeverReplacesLiveCatalog` while the test was named
`TestFailedFetchNeverDestroysLastKnownDrift`. Both functions existed, the
citation resolved, every gate stayed green, and the package's evidence described
something no run had ever executed. The `ratification-citations` row requires
the two to agree.

## Missing-signal report

```yaml
missing_signals:
  - behavior: <what happened in prod>
    indistinguishable_from: <what it currently looks like>
    proposed: <metric | trace attribute | structured event>
gate_attribution: |
  Would any declared gate have caught this? <which one / none, and why —
  this line feeds the framework's honest accounting even at N=1>
```
