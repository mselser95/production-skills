---
name: prod-ops
description: >
  Implementer skill (cheapest-model tier, highest frequency): the mechanical
  operations layer of a trunk-based pipeline — bisect a red trunk, author
  revert PRs with a human veto window, classify flakes (isolated rerun +
  changed-code intersection), manage quarantine, sweep expired liabilities
  (flags, waivers, quarantines, contract-migration debt), and rebase PRs
  ejected from the merge queue. Every operation is bounded, evidenced, and
  safe to run unattended within its rules. Absolute exception: a flaky T0
  invariant test is an INCIDENT, never a quarantine.
  The scheduled sweep additionally computes the four delivery keys from git
  and CI history as a TREND, never a gate.
  TRIGGER when: trunk is red ("bisect and revert"), a test flaked ("classify
  this flake"), registries need their sweep ("clean up expired flags"), an
  ejected PR needs rebasing, or on schedule as the standing maintenance loop.
  DO NOT TRIGGER when: the failure is a T0 invariant test (escalate as
  incident), the fix requires judgment about intended behavior (orchestrator
  work), or the ask is feature work.
---

# prod-ops — the mechanical layer

This skill is normally EXECUTED BY the `prod-mechanic` agent (pinned to the
cheapest model — see `references/dispatch.md`); each dispatch names ONE
operation below.

Read `references/preamble.md` first. Test provenance rules:
`references/test-provenance.md`. Registry paths come from `config.sh`
(`PROD_FLAGS_REGISTRY`, `PROD_WAIVERS_REGISTRY`, `PROD_QUARANTINE_REGISTRY`,
`PROD_CONTRACT_DEBT_REGISTRY`, and — only where the repo declares
`owning_domain` — `PROD_DOMAIN_BOUNDARIES_REGISTRY`, see
`references/domain-boundaries.md`); every entry has `owner`, `created`,
`expires`.

Reverting an agent's PR has zero social cost — that asymmetry is the design.
Act fast on solid signal, leave the veto window to humans, and never confuse
"mechanical" with "silent": every action lands as a PR or a registry change
with its evidence attached.

## Decision rules (these override everything else)

- **RULE T0-FLAKE:** a nondeterministic failure in a T0 invariant test is an
  INCIDENT. Do not quarantine, do not rerun-until-green, do not proceed —
  escalate with your reproduction evidence. Nondeterminism in a critical
  invariant test is as likely a product race as a test race.
- **RULE NO-DIRECT-DISABLE:** you never disable, delete, or weaken a test
  yourself. Quarantine expiry without a fix → open a DISABLE PR that requires
  the owner's approval (preamble §3), escalate, log. Never extend an expiry.
- **RULE ONE-REVERT:** one revert in flight per repo. A second red while one
  is open → escalate to a human, never stack reverts.
- **RULE NO-JUDGMENT:** any operation that turns out to need intent
  interpretation (which behavior is correct, which side of a semantic
  conflict wins) → BAIL with `blocked_on: judgment`. You execute defined
  operations; you never arbitrate meaning.
- **RULE EVIDENCE-FIRST:** no evidence, no action. Every revert, disable PR,
  quarantine entry, and closure carries its reproduction/bisect evidence
  inline.
- **RULE REGISTRY-ENTRIES-ONLY:** you operate on registry ENTRIES via the
  operations below. The registries' rules, TCB paths, CI config, and
  thresholds are never yours to change (preamble §3).

## Operations

### OP-1 Bisect a red trunk
- When: postsubmit red on trunk.
- Do: reproduce at HEAD first — if it does not reproduce in a fresh process,
  this is OP-3, not a bisect. Then bisect last-green..HEAD (short span on a
  queue-fed trunk). Confidence is `high` only with a clean non-flaky
  reproduction at the culprit AND green at its parent; anything less is `low`.
- Output: `CULPRIT <sha> <pr> confidence: high|low` + evidence.
- Handoff: `high` → OP-2. `low` → a human, with both runs attached; never
  open a revert on a low-confidence bisect.

### OP-2 Author a revert
- When: OP-1 handed off `high`, and RULE ONE-REVERT allows it.
- Do: open the revert PR into the priority lane — never push directly; the
  merge queue is the only writer. Body must contain: culprit SHA/PR, bisect
  evidence, failing job link, reproduction commands.
- Auto-merge policy: agent-authored culprit + high confidence → arm
  auto-merge after the veto window `PROD_REVERT_VETO_MINUTES` (default 15).
  Human-authored culprit OR any T0 path touched → request human approval,
  no auto-merge.
- Handoff: re-task the original author with the revert context. Re-land cap:
  2 attempts (fixed by design), then require a human.

### OP-3 Classify a flake
- When: a failure that does not reproduce, or fails-then-passes on the same
  commit.
- Do, in order: (1) isolated rerun — fresh process, same commit; (2) the
  changed-code intersection check: did the failing test execute ANY line the
  blamed commit changed? No ⇒ flake by construction; (3) stress the
  hypothesis — race detector, repeated runs, randomized order (Go example:
  `-race -count=N -shuffle=on`; adapt to the repo's language).
- Check RULE T0-FLAKE before anything else.
- The distinction step (1) draws — a *bohrbug* that reproduces on the isolated
  rerun and belongs to OP-1, versus a *heisenbug* that moves when observed and
  is what OP-4 holds — is Gray, "Why Do Computers Stop and What Can Be Done
  About It?" (Tandem TR-85.7, 1985).
- Output: classification + evidence + suspected class (async-wait, ordering,
  isolation, timing) → OP-4 entry + owner notification.

### OP-4 Quarantine registry
- When: OP-3 classified a non-T0 flake.
- Do: add entry to `PROD_QUARANTINE_REGISTRY` — test id, evidence link,
  `owner` from the repo's ownership map, `expires` = now +
  `PROD_QUARANTINE_TTL_DAYS` (default 14; use 3 for tests guarding critical
  paths — fixed by design). Quarantined = keeps running, stops gating.
- On expiry without a fix: RULE NO-DIRECT-DISABLE.

### OP-5 Liability sweep
- When: scheduled, or on request.
- Do, per registry, for each entry past `expires`:
  - flag (`PROD_FLAGS_REGISTRY`) → open the removal PR: dead arm deleted,
    safe default kept, both arms' tests updated.
  - waiver (`PROD_WAIVERS_REGISTRY`) → the suppressed gate returns to force;
    notify owner.
  - contract-migration debt (`PROD_CONTRACT_DEBT_REGISTRY`) → open the
    ticket for the pending destructive step; NEVER author destructive DDL.
  - domain-boundary exception (`PROD_DOMAIN_BOUNDARIES_REGISTRY`, if declared)
    → the waived direct-access path returns to force; notify the owner. This
    is RULE NO-JUDGMENT territory the moment "still migrating" is asserted —
    that is a human call, never yours to extend.
  - agent PR stale >48h or ejected twice (fixed by design) → close with a
    state-dump comment.
- Output: sweep report — entries actioned, entries escalated, owners pinged.

### OP-6 Rebase an ejected PR
- When: the merge queue ejected a PR (stale base or textual conflict).
- Do: mechanical rebase onto trunk. Textual conflict → re-task the authoring
  agent with the conflict context, cap 2 retries, then OP-5 closure.
  Semantic conflict (both sides changed behavior) → RULE NO-JUDGMENT.

### OP-7 Delivery metrics (trend)
- When: on the OP-5 sweep's cadence, as part of that scheduled run. Not on
  demand, and never as an input to a release decision — see the stance below.
- Do: compute the four delivery keys from history this repo already keeps —
  git log plus the CI/deploy record. This operation adds no instrumentation
  and no new registry; if a key's input does not exist, that is what you
  report for it.
  - **deployment frequency** — deploys reaching production per window.
  - **lead time for changes** — first commit of a merged change to the deploy
    that carried it; report the median and the p85, because the tail is where
    the batching lives.
  - **time to restore service** — the postsubmit red that opened OP-1 to the
    merge of the OP-2 revert or the fix-forward that turned the same job
    green. Both ends are already timestamped by those operations, which is
    the only reason this key is cheap here.
  - **change failure rate** — deploys followed inside the window by a revert,
    a rollback, or a declared incident, over all deploys.

  Two windows, both reported (30 and 90 days — fixed by design): one window
  states a level, and only the pair states a direction.
- Output: four numbers with their windows, appended to the OP-5 sweep report.
  Name every key you could NOT compute and the input that was missing — a
  repo with no deploy record leaves three of these uncomputable, and printing
  that is the finding; printing a plausible number instead is the vacuous
  form of this operation.
- **TREND ONLY, never a gate.** The same stance this framework already takes
  on mutation scores: reported in the trend lane, no threshold, no registry
  entry, no escalation path out of this operation. A delivery key that gates
  anything stops being measured and starts being produced — deferring a
  revert so restore time reads better is the failure mode, and it inverts
  exactly the asymmetry the top of this file relies on.
- Source: Forsgren, Humble & Kim, *Accelerate* (IT Revolution, 2018) — the
  four keys, and their correlation with organizational performance measured
  across a survey population. A correlation over organizations licenses a
  direction to watch in one repo; it does not license a pass/fail line here.

**Chaos and liability operations have runnable references.** `demos/INDEX.md`
carries the executable form of several conditions this skill acts on — a
metastable collapse that outlives its trigger (retry-storm), a component whose
self-report stays green while clients fail (gray-failure). When classifying an
incident-shaped failure, comparing it against a demo that reproduces the shape
is cheaper than arguing from the logs.

## Bail

Preamble format. The expected `blocked_on` values: `judgment`,
`t0-flake-incident` (with the escalation already sent), `registry-missing`
(a configured registry path does not exist — name it).
