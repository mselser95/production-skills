---
name: prod-ops
description: >
  Implementer skill (cheapest-model tier, highest frequency): the mechanical
  operations layer of a trunk-based pipeline — bisect a red trunk, author
  revert PRs (aggressive threshold for agent-authored culprits, human veto
  window), reproduce and classify flakes (isolated rerun + changed-code
  intersection), manage the quarantine registry, sweep expired liabilities
  (flags, waivers, quarantines, contract-migration debt), and rebase/re-task
  PRs ejected from the merge queue. Every operation is bounded, verifiable,
  and safe to run unattended within its rules. The one absolute exception:
  a flaky T0 invariant test is an INCIDENT, never a quarantine.
  TRIGGER when: trunk is red ("bisect and revert"), a test flaked ("classify
  this flake"), the liability registries need their sweep ("clean up expired
  flags/waivers"), a queue-ejected PR needs rebasing, or on a schedule as the
  pipeline's standing maintenance loop.
  DO NOT TRIGGER when: the failure is a T0 invariant test (escalate as
  incident — prod-incident territory once analyzed), the fix requires judgment
  about intended behavior (orchestrator work), or the ask is feature work.
---

# prod-ops — the mechanical layer

Read `references/preamble.md` first. Registry entries follow the liability
convention: every entry has `owner`, `created`, `expires`.

Reverting an agent's PR has zero social cost — that asymmetry is the design.
Act fast on solid signal, leave the veto window to humans, and never confuse
"mechanical" with "silent": every action lands as a PR or a registry change
with a paper trail.

## Operations

### 1. Bisect a red trunk
- Span: last-green..HEAD (short, on a queue-fed trunk).
- Reproduce the failure at HEAD first; a non-reproducing failure goes to the
  flake path (op 3), not to bisection.
- Bisect to the culprit; confidence requires a clean non-flaky reproduction at
  the culprit and green at its parent.
- Output: `CULPRIT <sha> <pr> confidence: high|low` + hand-off to op 2 (high)
  or a human (low).

### 2. Author a revert
- Open the revert PR into the priority lane with the bisect evidence in the
  body. Never push directly — the merge queue is the only writer.
- Agent-authored culprit + high confidence: mark for auto-merge after the
  veto window (`PROD_REVERT_VETO_MINUTES`, default 15). Human-authored or
  T0-touching culprit: request human approval, no auto-merge.
- Re-task the original author (agent: structured re-task with the failure;
  human: notify) — cap re-lands at 2, then require a human.

### 3. Reproduce and classify a flake
- Isolated rerun (fresh process, same commit). Then the DeFlaker check: did
  the failing test execute ANY line changed by the blamed commit? No ⇒ flake.
- Stress the hypothesis: `-race`, `-count=N`, shuffle. Record the evidence.
- **T0 invariant test: STOP.** Nondeterminism in a critical-invariant test is
  as likely a product race as a test race. Escalate as an incident with your
  reproduction evidence; do not quarantine, do not rerun-until-green.
- Otherwise: quarantine entry (op 4) + a reproduction report the owner can
  act on (the suspected class: async-wait, ordering, isolation, timing).

### 4. Quarantine registry
- Entry: test id, evidence link, `owner` (the test's owner per the repo's
  ownership map), `expires` (`PROD_QUARANTINE_TTL_DAYS`, default 14; 3 for
  T1-critical). Quarantined = keeps running, stops gating.
- On expiry without a fix: disable the test, escalate to the owner, log it.
  You never silently extend an expiry.

### 5. Liability sweep (flags, waivers, contract debt, stale PRs)
- For each registry: list entries past `expires`.
- Expired flag → open the removal PR (both arms' tests updated per the flag's
  documented default — the safe state stays; the dead arm goes).
- Expired waiver → the gate it suppressed goes back into force; notify owner.
- Expired contract-migration debt (expand without contract) → open the ticket
  with the pending destructive step; never author destructive DDL yourself.
- Agent PR stale >48h or ejected twice → close with a state dump comment.

### 6. Rebase an ejected PR
- Mechanical rebase onto current trunk; on textual conflict, re-task the
  authoring agent with the conflict context (2 retries then close per op 5).
- Never resolve a semantic conflict by choosing sides — that is judgment.

## Guardrails

- Preamble §3: CI config, thresholds, and the registries' RULES are TCB. You
  execute the defined operations on registry ENTRIES; you never change what
  the registry enforces.
- Every destructive-looking action (revert, disable, close) carries its
  evidence inline. No evidence, no action.
- Rate-limit yourself: one revert in flight per repo at a time; a second red
  while one is open means escalate, not stack reverts.

## Bail

Preamble format. The common one: `blocked_on: judgment` — the operation turned
out to need intent interpretation (whose behavior is correct, which side of a
conflict wins). Park the evidence, name the human or orchestrator skill.
