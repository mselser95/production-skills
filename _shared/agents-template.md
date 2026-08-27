# AGENTS.md template — the routing contract prod-bootstrap installs

`prod-bootstrap` instantiates this file at the target repo's root as
`AGENTS.md` (symlinked or duplicated as `CLAUDE.md` per the org's loader),
filling the `<...>` slots from the ratified spec. It is the enforcement
surface the framework has inside every conversation: any agent loading the
repo reads this FIRST, and every request routes through the pipeline — no
step skipped because the ask "seems small".

---

```markdown
# AGENTS.md — <repo> (tier T<k>)

This repository is governed by a production-verifiability standard. Every
task an agent performs here — feature, fix, refactor, "quick change" —
follows the pipeline below. There is no size threshold under which these
steps are optional.

## The pipeline (always, in order)

1. **Context first, code never first.** Before writing any code, produce or
   obtain the resolved context and change plan for the task (`prod-spec`).
   If this repo's tier is 0, the resolved context requires human approval
   before implementation starts.
2. **Implement inside the contract** (`prod-implement`): one bounded task at
   a time, tests with the code carrying provenance headers, iterating
   against the cheap gate (`<cheap gate command>`), then the presubmit
   (`<presubmit command>`).
3. **Validate everything before calling it done** (`prod-review`): the diff
   is reviewed against its resolved context — divergence recompute, gap
   discovery, provenance audit, and the deep pass. Findings go back to step
   2; "done" means the verdict is contract-satisfied and every required gate
   is green, not that the code compiles.
4. **Incidents feed back** (`prod-incident`): a production defect is closed
   only with its minimized fixture, candidate invariant, and missing-signal
   report.

## Hard rules for any agent in this repo

- `verification/ratified/**`, CI configuration, the liability registries'
  rules, and existing tests are NOT yours to modify. A task that seems to
  require it is a finding for a human, not an edit.
- Never modify or delete an existing test to make your change pass.
- New tests carry provenance headers; candidates go to the advisory lane.
- An obligation you cannot satisfy becomes a waiver proposal with an expiry
  — never a silent skip.
- If the task is ambiguous enough to change its capability mapping or tier:
  ask, don't guess.
- <IF DOMAIN-AWARE> A new dependency reaching another domain's capability
  that is not classed `domain_gateway` is a boundary violation, not a style
  finding — flag it, do not route around it by finding a lower-level path to
  the same data.
- Every completion ends with the evidence summary (gates green, tests by
  provenance class, deviations declared). No evidence summary = not done.

## This repo's contract

- Spec: `<PROD_SPEC_FILE>` — tier, invariants, capabilities. Read it.
- Zones: core = `<core paths>` (pure), orchestration = `<paths>`,
  shell/adapters = `<paths>`.
- Cheap gate: `<command>` · Presubmit: `<command>`
- Regressions corpus: `<PROD_REGRESSIONS_DIR>/` · Ratification queue:
  `<PROD_RATIFY_QUEUE_DIR>/`
- Blocker bar for reviews: <one line — what class of damage blocks merge>
- <IF DOMAIN-AWARE> Domain: `<owning_domain>` (`<domain_role>`) · depends on:
  `<domain_dependencies, each with its via: gateway>` · this repo's own
  gateway capability, if any: `<domain_gateway capability id, or none>`
```

---

Instantiation rules for prod-bootstrap:

- Every `<slot>` is filled from a ratified Phase-2 answer or a Phase-1
  detection the human confirmed — never from inference.
- If the repo already has an AGENTS.md/CLAUDE.md, MERGE by appending the
  pipeline section and hard rules; never delete existing guidance — flag
  conflicts to the human instead.
- `<IF DOMAIN-AWARE>` lines are instantiated only when `_shared/domain-
  topology.yaml` exists AND this repo declares `owning_domain` — otherwise
  drop both lines entirely rather than filling them with "N/A" (see
  `domain-boundaries.md`: absence is a silent, legitimate N/A, never a row).
- The file is part of the repo's TCB surface once installed: agents may not
  weaken it, and changes to it get human review like any ratified artifact.
