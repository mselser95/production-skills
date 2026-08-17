---
name: prod-review
description: >
  Orchestrator skill: adversarial review of a diff AGAINST ITS RESOLVED CONTEXT
  — not a general code review. Recomputes the obligations from the actual diff
  (paths → zones/tier, touched ports → capabilities) and hard-flags divergence
  from what prod-spec claimed; runs gap discovery (new dependency without a
  failure model, new state without recovery semantics, new failure branch
  without an observable signal, complexity change without a benchmark, semantic
  change with the spec untouched); and audits test changes for provenance
  violations (weakened assertions, deletions, candidates posing as blocking).
  Emits structured findings; fixes nothing.
  TRIGGER when: a change produced under a resolved context needs review
  ("review this against the contract", the post-implement step of a prod-*
  pipeline, or a PR whose branch carries a resolved-context artifact).
  DO NOT TRIGGER when: there is no resolved context for the change (use the
  org's general review skill instead), or the user wants fixes applied
  (that goes back to prod-implement with these findings as input).
---

# prod-review — claimed vs actual, then gaps

Read `references/preamble.md` first. Consumes
`references/resolved-context.md` and `references/change-plan.md` artifacts;
audits provenance per `references/test-provenance.md`.

The framing matters: `prod-spec`'s interpretation is a **hint**. This skill is
the deterministic-side check that the hint matched reality. You are not here to
like the code; you are here to refute the claim that the contract was followed.

## Contract

- **Input:** the diff (branch or PR), the task's `resolved-context.yaml` and
  `change-plan.yaml`.
- **Output:** a structured findings report (format below). No commits, no
  comments posted unless `PROD_REVIEW_POST=true` in `config.sh`.

## Algorithm

1. **Recompute obligations from the diff.** From the actual changed paths and
   symbols, derive independently: which zones (core/orchestration/shell),
   which capabilities (which ports/adapters were touched), which semantic
   events actually occurred. THEN compare with the claimed context:
   - touched a capability not in `capabilities.touched` → **DIVERGENCE**
   - semantic event occurred that the plan didn't declare → **DIVERGENCE**
   - tier of touched paths higher than context `tier` → **DIVERGENCE**
   Any divergence is a blocker by definition — the loop optimized the wrong
   contract, and everything downstream of it is unaudited.
2. **Gap discovery** — the checklist, applied to what the diff introduces:
   - new external dependency → timeout? retry policy? failure model?
     observability? resilience scenarios in the plan?
   - new state/transition → crash-here semantics? retry class? reconciled by
     what? observable outcome?
   - new failure branch → distinguishable in production from existing
     failures? (a `return err` with no new signal is a gap)
   - loop/fanout over a collection that used to be O(1) → benchmark scenario?
   - semantic change with `production.yaml` and capability files untouched →
     either the spec must change or the PR must assert it remains complete.
3. **Test-change audit.** For every test file in the diff:
   - deleted test or weakened assertion → **BLOCKER: human review required**
     (preamble §3), regardless of tier.
   - new test without a provenance header → finding.
   - `provenance: ratified|derived` whose `verifies:` doesn't resolve →
     finding (that header is a claim; an unresolvable claim is laundering).
   - exact-value assertions with no ratified property behind them, not marked
     `pinning: true` → finding.
4. **Evidence check.** Every entry in `required_evidence.gates` has a
   corresponding green result for THIS diff; missing evidence is a gap, not a
   promise.

## Output format

```
FINDINGS
- id: F1
  class: DIVERGENCE|GAP|PROVENANCE|EVIDENCE
  severity: BLOCKER|WARNING
  where: <file:line or artifact>
  claim: <what the context/plan said, if applicable>
  actual: <what the diff does>
  required: <the specific remediation — actionable, one step>
VERDICT: contract-satisfied | blocked (<n> blockers)
```

## Guardrails

- You fix nothing. Findings go back to `prod-implement` (or a human).
- You do not soften DIVERGENCE findings because the code "looks right" — the
  point is that nobody audited it against the right contract.
- If two reviews of the same diff would disagree (you are uncertain), say so
  in the finding rather than inflating severity to win.

## Bail

Preamble format. Mandatory bail: no resolved-context artifact exists for the
diff → this skill does not apply; say which skill does.
