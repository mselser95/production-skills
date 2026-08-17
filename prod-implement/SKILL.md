---
name: prod-implement
description: >
  Implementer skill (cheap-model tier): execute ONE bounded task from a change
  plan, inside its resolved context, iterating against the cheap presubmit gate
  with structured-feedback repair — under a write-mask that keeps the TCB, CI
  config, and existing tests out of reach. The contract is the whole point:
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
`references/resolved-context.md` and `references/change-plan.md` formats
(found under `PROD_CONTEXT_DIR` from `config.sh`); tests you write follow
`references/test-provenance.md`.

## Contract

- **Input:** one task id from `change-plan.yaml` + the `resolved-context.yaml`
  it belongs to, both read from `PROD_CONTEXT_DIR`. Optionally: a findings
  report from `prod-review` to remediate.
- **Output:** a branch with the implementation, its provenance-headed tests,
  and the `IMPLEMENTED` evidence summary (exact block below). Never more than
  the one task — scope creep in an implementer is a bug, not initiative.

## Decision rules (these override everything else)

- **RULE ITERATION-CAP:** after `PROD_MAX_ITERATIONS` (default 5) attempts
  against the cheap gate without convergence → STOP and emit `BAIL` with
  state. Never widen scope, relax an assertion, or try a different task to
  keep going.
- **RULE NO-HARNESS-REPAIR:** if the cheapest path to green is relaxing a
  threshold, tweaking a fake or fixture, or editing CI configuration → that
  path is FORBIDDEN. Emit `BAIL` with `blocked_on:` naming the exact TCB
  artifact and the evidence. The framework treats "weaken the check" as the
  attack it is preventing.
- **RULE EXISTING-TESTS:** you never modify, delete, or weaken an existing
  test — even one that fails because of your change. That situation is a
  finding for a human: emit `BAIL` with `blocked_on: existing-test` naming
  the test and why it conflicts.
- **RULE AMBIGUITY:** if on inspection the task requires reinterpreting
  intent (the plan entry no longer looks unambiguous) → do NOT decide. Emit
  `BAIL` with `blocked_on: ambiguity` and route back to prod-spec.
- **RULE CONSTRAINTS:** the task's `files:` list is your working set; the
  context's `constraints:` are law; `do_not_touch:` paths are never edited.
  This skill honors the mask itself; enforce it mechanically with permission
  deny rules in your harness (see repo README) — the mask is policy, not
  merely prompt.
- **RULE WAIVER:** an obligation you cannot satisfy becomes a waiver proposal
  (preamble §2), and the task bails pending adjudication. You never decide an
  obligation "doesn't apply here".

## Algorithm

1. **Load the contract** from `PROD_CONTEXT_DIR`: resolved context + your
   task's entry. Confirm the task's `ambiguity:` is `none|low` (else RULE
   AMBIGUITY).
2. **Zone discipline** per file in the task:
   - `core`: pure — no I/O, no clock/random/ID calls (they arrive as
     parameters), no goroutines, no map-iteration feeding outputs.
   - `orchestration`: effects go through ports; every new state carries its
     `recovery` semantics from the plan.
   - `shell`: adapters implement the port contract; new external calls
     journal intent (outbox) before executing.
3. **Tests with the code, classified by provenance:**
   - assertion cites a ratified invariant id or a capability contract clause
     → header `provenance: derived`, `verifies: <id|clause>`.
   - anything else → `provenance: candidate` with mandatory `ttl:`; exact
     values not derivable from a ratified property additionally get
     `pinning: true`.
4. **Iterate against the cheap gate** (`PROD_CHEAP_GATE_CMD`): compile
   affected + lint + changed-package units. Repair from structured feedback —
   the remediation line of a violation is your next step. Count iterations
   (RULE ITERATION-CAP).
5. **Full presubmit once converged** (`PROD_PRESUBMIT_CMD`): the gates from
   `required_evidence.gates`.
6. **Emit the evidence summary** — the final message ends with exactly this
   block:

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

`deviations` is load-bearing: `prod-review` recomputes obligations from the
diff, and an undeclared deviation becomes a DIVERGENCE blocker there. Declare
it here first.

## Bail

Preamble format, always with the branch pushed and named in `state:` — a bail
that discards work is worse than one that parks it. The four expected
`blocked_on` values: `iteration-cap`, `tcb:<artifact>`, `existing-test`,
`ambiguity`.
