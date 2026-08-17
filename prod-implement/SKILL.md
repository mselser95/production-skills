---
name: prod-implement
description: >
  Implementer skill (cheap-model tier): execute ONE bounded task from a change
  plan, inside its resolved context, iterating against the cheap presubmit gate
  with structured-feedback repair — under a hard write-mask that keeps the TCB,
  CI config, and existing tests out of reach. The contract is the whole point:
  this skill assumes the ambiguity was already resolved by prod-spec, so its
  job is convergence, not judgment. Bounded iterations, honest bail with state.
  TRIGGER when: a change-plan task with ambiguity none|low needs implementing
  ("implement T2 of the plan", the execution step of a prod-* pipeline).
  DO NOT TRIGGER when: there is no resolved context / change plan (run
  prod-spec first), the task is marked ambiguity open (that is orchestrator
  work), or the ask is to fix review findings on TCB artifacts (human).
---

# prod-implement — one task, inside the contract

Read `references/preamble.md` first. Inputs are artifacts in
`references/resolved-context.md` and `references/change-plan.md` formats;
tests you write follow `references/test-provenance.md`.

## Contract

- **Input:** one task id from `change-plan.yaml` + the `resolved-context.yaml`
  it belongs to. Optionally: a findings report from `prod-review` to remediate.
- **Output:** a branch with the implementation, its provenance-headed tests,
  and an evidence summary (below). Never more than the one task — scope creep
  in an implementer is a bug, not initiative.

## Algorithm

1. **Load the contract.** Resolved context + your task's entry. The `files:`
   list is your working set; the `constraints:` block is law; `do_not_touch:`
   is enforced by permissions but you honor it before hitting the wall.
2. **Zone discipline.** Respect the task's `zone:` per file:
   - `core`: pure — no I/O, no clock/random/ID calls (they arrive as
     parameters), no goroutines, no map-iteration feeding outputs.
   - `orchestration`: effects go through ports; every new state carries its
     `recovery` semantics from the plan.
   - `shell`: adapters implement the port contract; new external calls journal
     intent (outbox) before executing.
3. **Tests with the code.** Every behavior you add gets tests in the SAME
   change: assertions that cite a ratified invariant or contract clause carry
   `provenance: derived`; anything else is `candidate` with a TTL. You never
   modify or delete an existing test — if one blocks you, that is a finding
   for a human (preamble §3), reported, not "fixed".
4. **Iterate against the cheap gate** (`PROD_CHEAP_GATE_CMD`): compile
   affected + lint + changed-package units. Repair from structured feedback —
   the remediation line of a violation is your next step, not a suggestion.
   **Iteration cap: `PROD_MAX_ITERATIONS` (default 5).** Hitting the cap is a
   bail, not a license to try harder by widening scope.
5. **Full presubmit once converged** (`PROD_PRESUBMIT_CMD`): the required
   gates from `required_evidence.gates`. Green ⇒ emit the evidence summary.
6. **Evidence summary** (final output, always):

```
IMPLEMENTED
task: <id> — <summary>
branch: <name>
files: <changed>
tests: <n derived / n candidate, headers verified>
gates: <each required gate: green + run reference>
signals: <coverage on changed lines, surviving mutants if surfaced>
deviations: none | <anything done differently from the plan, and why>
```

`deviations` is load-bearing: `prod-review` recomputes from the diff, and an
undeclared deviation becomes a DIVERGENCE blocker there. Declare it here first.

## Guardrails

- Preamble in full. The three that bite implementers:
  - **Never repair the harness.** If a gate fails because of a fixture, a
    threshold, a fake, or CI config — that is a BAIL with the evidence, not an
    edit. The cheapest path to green being "weaken the check" is exactly the
    failure mode this skill's design prevents.
  - **Never invent policy** (§2): an obligation you can't satisfy becomes a
    waiver request, and the task bails pending it.
  - **Candidate lane only** for tests whose assertions you derived yourself.
- Stay on model: this skill is written to be executable by a small model.
  If you find yourself needing to re-interpret the intent, the task was
  mis-scoped — bail with `blocked_on: ambiguity`, route back to prod-spec.

## Bail

Preamble format, plus: always leave the branch pushed with WIP state named in
`state:` — a bail that discards work is worse than one that parks it.
