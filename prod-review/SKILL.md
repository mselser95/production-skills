---
name: prod-review
description: >
  Orchestrator skill: hard senior review of a diff AGAINST ITS RESOLVED
  CONTEXT, with a full audit engine underneath — no approval bias, full-file
  reading, repo-idiom recon so house style is never flagged as a defect, and a
  blocker bar injected from config. Three contract phases (recompute
  obligations from the diff and flag divergence from what prod-spec claimed;
  gap discovery — new dependency without failure model, new state without
  recovery, new failure branch without a signal; provenance audit of test
  changes) plus the deep pass over architecture, logic, data, errors,
  observability, performance, cross-boundary contracts, tests, and
  completeness. Emits classified findings with file:line citations; fixes
  nothing.
  TRIGGER when: a change produced under a resolved context needs review
  ("review this against the contract", the post-implement step of a prod-*
  pipeline, or a PR whose branch carries a resolved-context artifact).
  DO NOT TRIGGER when: there is no resolved context for the change (use the
  org's general review skill instead), or the user wants fixes applied
  (that goes back to prod-implement with these findings as input).
---

# prod-review — claimed vs actual, then gaps, then the deep pass

Read `references/preamble.md` first, then `references/review-depth.md` — the
audit engine: its Hard Rules, idiom layer, severity buckets, and review areas
govern every finding this skill produces. Contract artifacts follow
`references/resolved-context.md` and `references/change-plan.md` (read from
`PROD_CONTEXT_DIR`); test provenance per `references/test-provenance.md`. If
the diff's repo declares `owning_domain`, also read
`references/domain-boundaries.md` before Phase 1.

The framing matters: `prod-spec`'s interpretation is a **hint**. This skill is
the deterministic-side check that the hint matched reality, followed by an
unsparing senior review of the code itself. You are not here to like the code;
you are here to refute the claim that the contract was followed and that the
change is production-grade.

## Contract

- **Input:** the diff (branch or PR), the task's `resolved-context.yaml` and
  `change-plan.yaml` from `PROD_CONTEXT_DIR`, plus `PROD_BLOCKER_CALIBRATION`
  and `PROD_DOMAIN_CONTEXT` from `config.sh`.
- **Output:** a classified findings report (format below). No commits; no
  comments posted unless `PROD_REVIEW_POST=true`.

## Algorithm

Dispatch per `references/dispatch.md`: on large diffs, Phase 0's conventions
recon and full-file reading fan out to `prod-scout` agents (cheap); judgment
(phases 1–5 verdicts, calibration) stays on the session model.

### Phase 0 — Recon (before any finding exists)
Read the repo's conventions: agent/contributor docs, linter config, and the
dominant patterns in the untouched code around the diff. This feeds the idiom
layer — the single largest source of false positives is skipping this. Then
read EVERY changed file in full, not hunks.

### Phase 1 — Recompute obligations from the diff
From the actual changed paths and symbols, derive independently: which zones
(core/orchestration/shell), which capabilities (which ports/adapters were
touched), which semantic events actually occurred. THEN compare with the
claimed context:
- touched a capability not in `capabilities.touched` → **DIVERGENCE**
- semantic event occurred that the plan didn't declare → **DIVERGENCE**
- tier of touched paths higher than context `tier` → **DIVERGENCE**
- `owning_domain` declared and the diff adds a dependency crossing it that
  `crosses_domain_boundary` didn't flag → **DIVERGENCE**
Any divergence is a BLOCKER by definition — the loop optimized the wrong
contract, and everything downstream of it is unaudited.

### Phase 2 — Gap discovery
The framework checklist, applied to what the diff introduces:
- new external dependency → timeout? retry policy? failure model?
  observability? resilience scenarios in the plan?
- new state/transition → crash-here semantics? retry class? reconciled by
  what? observable outcome?
- new failure branch → distinguishable in production from existing failures?
  (a bare error return with no new signal is a gap)
- loop/fanout over a collection that used to be O(1) → benchmark scenario?
- semantic change with the spec (`PROD_SPEC_FILE`) and capability
  declarations untouched → either the spec changes or the PR asserts it
  remains complete.
- new dependency reaching another domain (`owning_domain` declared) → does it
  resolve to a `domain_gateway`-classed capability in the target's own spec?
  Unresolvable (target repo unavailable) → gap, not a pass
  (`references/domain-boundaries.md`).

### Phase 3 — Provenance audit
For every test file in the diff:
- deleted test or weakened assertion → **BLOCKER: human review required**
  (preamble §3), regardless of tier.
- new test without a provenance header → finding.
- `provenance: ratified|derived` whose `verifies:` doesn't resolve → finding
  (that header is a claim; an unresolvable claim is laundering).
- exact-value assertions with no ratified property behind them, not marked
  `pinning: true` → finding.
- coverage theater (mock-was-called assertions, re-asserted implementation
  arithmetic) → finding even when the coverage number is fine.

### Phase 4 — The deep pass
Apply every review area in `references/review-depth.md` (architecture &
boundaries, logic & bugs, data & persistence, error handling, observability,
performance, cross-boundary contracts, tests, completeness, stale docs) to
the full files read in Phase 0. Every area is checked or explicitly listed
`NOT VALIDATED` with the reason — silence is not OK. Cross-boundary changes
get their counterpart verified at its source, never assumed from compilation.

### Phase 5 — Evidence check
Every entry in `required_evidence.gates` has a corresponding green result for
THIS diff; missing evidence is a gap, not a promise.

## Output format

```
FINDINGS
- id: F1
  class: DIVERGENCE|GAP|PROVENANCE|EVIDENCE|CORRECTNESS
  severity: BLOCKER|WARNING|MISSING-TESTS
  where: <file:line — mandatory; no citation, no finding>
  claim: <what the context/plan/description said, if applicable>
  actual: <what the code does>
  required: <the specific remediation — actionable, one step>
NOT VALIDATED
- <area>: <why it could not be verified>
VERDICT: contract-satisfied | blocked (<n> blockers)
```

## Guardrails

- The Hard Rules of `review-depth.md` bind: default to findings; cite
  file:line always; never inflate to be safe (a false blocker teaches the
  team to ignore blockers); MISSING-TESTS on new code always survives and
  never gets challenged away.
- The idiom layer binds: a consistent house pattern is the standard; an
  enabled linter rule is CI's finding, not yours.
- You fix nothing. Findings go back to `prod-implement` (or a human).
- You do not soften DIVERGENCE findings because the code "looks right" — the
  point is that nobody audited it against the right contract.

## Bail

Preamble format. Mandatory bail: no resolved-context artifact exists for the
diff → this skill does not apply; say which skill does.
