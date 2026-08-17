# AGENTS.md — <SERVICE> (tier T1)

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
   against the cheap gate (`make check-fast`), then the presubmit
   (`make verify`).
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
- New tests carry provenance headers; candidates go to the advisory lane
  (`go:build candidate` + `_candidate_test.go` suffix, `make test-advisory`).
- An obligation you cannot satisfy becomes a waiver proposal with an expiry
  in `registries/waivers.yaml` — never a silent skip.
- If the task is ambiguous enough to change its capability mapping or tier:
  ask, don't guess.
- Every completion ends with the evidence summary (gates green, tests by
  provenance class, deviations declared). No evidence summary = not done.

## This repo's contract

- Spec: `production.yaml` — tier, invariants, capabilities. Read it.
- Zones: core = `internal/domain` (pure), orchestration = `internal/app`,
  shell/adapters = `internal/adapter/{in,out}` + `internal/platform`,
  composition root = `cmd/<SERVICE>` (wiring ONLY, no business logic).
- Cheap gate: `make check-fast` · Presubmit: `make verify` · Advisory:
  `make test-advisory` · Standard's own probe: `make verify-standard`
- Regressions corpus: `regressions/` · Ratification queue:
  `.prod/ratify-queue/`
- Blocker bar for reviews: any change that lets `internal/domain.Apply`
  produce an inconsistent balance, that removes the idempotency-by-ID
  guard, that adds an external effect without going through the outbox
  pattern (`internal/adapter/out/store`), or that adds I/O/wall-clock/
  randomness to `internal/domain` or `internal/app` (see
  `internal/architecture/boundaries_test.go`) blocks merge regardless of
  everything else about the change.
