---
name: prod-curate
description: >
  Curation skill (mixed tier): run the promotion pipeline that moves
  candidate-lane tests toward the blocking lane in BATCHES — change-detector
  screening against a corpus of real refactor commits, mutant-utility dedup
  (kills nothing new ⇒ discard), known-bad kata checks (a suite that passes a
  deliberately broken implementation fails regardless of scores) — and
  assemble ratification packages for invariant candidates (statement +
  both-direction evidence + contradiction-check + prod soak) so human
  adjudication takes minutes, not hours. The skill prepares; the human
  ratifies. Nothing here lands in the blocking lane without that approval.
  TRIGGER when: a promotion batch is due ("curate the candidate lane",
  "prepare the ratification queue", scheduled batch runs), or invariant
  candidates have accumulated from prod-spec/prod-incident.
  DO NOT TRIGGER when: someone wants a single test promoted ad-hoc (promotion
  is batch-only by design), or wants the ratified set edited directly (human,
  through the TCB flow — this skill only ever proposes).
---

# prod-curate — screening and ratification packages

Read `references/preamble.md` first. Promotion rules live in
`references/test-provenance.md`; invariant package format in
`references/incident-fixture.md`.

Two corpora are this skill's working capital (paths in `config.sh`):
- `PROD_REFACTOR_CORPUS`: real behavior-preserving commits from the repo's
  history (screening oracle for change-detectors).
- `PROD_KATA_DIR`: deliberately broken implementations per capability class
  (wrong rounding, dropped idempotency key, off-by-one, swallowed error).
  Two further classes belong here, both of them breakages a suite assembled
  from happy-path clauses will sail straight through — which is precisely
  what makes them worth staging:
  - **overload kata** — a retry loop with no bound, no budget and no
    shedding: correct against a fast downstream, and under a slow one each
    client retry adds load to the thing already saturated, so the system
    stays collapsed after the trigger is gone. A candidate suite must FAIL
    this kata; a suite that exercises only the nominal latency passes it, and
    that pass is the finding, because dimension 26 (overload and
    metastability) is the failure this kata stages in miniature.
  - **error-handling kata** — a handler that catches a fatal error and
    carries on: logged and swallowed, or the error variable overwritten
    before it is returned, so the caller sees success. Yuan et al., "Simple
    Testing Can Prevent Most Critical Failures" (OSDI 2014), found that 92%
    of catastrophic failures in the distributed systems they studied followed
    the incorrect handling of an error the software had ALREADY signalled,
    and that a large share of those handlers were trivially wrong. The kata
    is cheap to write for that reason, and a suite that passes it is asserting
    outputs while the error path decides the outcome.

Maintain both: every sweep, add newly-identified refactor commits and any kata
gap you found. A stale corpus screens nothing.

Dispatch per `references/dispatch.md`: the mechanical runs (steps 2–4 —
corpus replays, mutation dedup, kata runs) go to `prod-mechanic` agents;
eligibility decisions, sampling, and ratification packages stay on the
session model.

## Algorithm — test promotion (batch)

1. **Collect eligibles:** candidate-lane tests inside their TTL that have run
   ≥ `PROD_MIN_ADVISORY_RUNS` times with a stable record and without
   `pinning: true`.
2. **Change-detector screening:** run each against every commit in the
   refactor corpus. A test that fails on ANY behavior-preserving commit is a
   change detector → reject, note the commit that caught it.
3. **Mutant-utility dedup:** run the mutation set (`PROD_MUTATION_CMD`) with
   the blocking lane alone, then blocking + candidate. A candidate that kills no mutant the blocking
   lane misses adds risk without signal → discard (recorded, not deleted
   early — TTL handles deletion).
4. **Kata check:** the candidate suite must FAIL on every kata for its
   capability. Passing a known-bad implementation means the oracle points the
   wrong way; scores cannot detect that — this check exists for it.
5. **Sample for human review:** `PROD_PROMOTION_SAMPLE_PCT` (default 20%) of
   survivors, chosen randomly, presented with their citations.
6. **Emit the promotion batch PR:** survivors re-headed as `derived` (with the
   reproducible derivation shown) — targeting the blocking lane but merging
   only with human approval. Body: per-test screening evidence table.

## Algorithm — invariant ratification queue

1. Collect candidates from `PROD_RATIFY_QUEUE_DIR` (where prod-spec plans,
   prod-incident packages, and counterexample-search runs deposit them).
2. **Mechanical pre-filter, before any human sees them:**
   - falsifiability: package has BOTH passing runs and a concrete violating
     trace; missing either ⇒ back to author with the gap named.
   - contradiction-check vs declared capability contracts ⇒ CONFLICT rejects
     (or flags the contract itself for human attention — never both silently).
   - duplicates/implications vs the ratified set ⇒ merged or dropped.
3. **Respect the budget:** at most `PROD_RATIFY_BUDGET_PER_WEEK` per service
   reach the human, ranked by (incident-derived first, then coverage of
   uncovered capabilities). Overflow expires back to the queue — scarcity is
   what keeps review real.
4. **Package for minutes-not-hours:** one page per candidate — statement,
   both-direction evidence, contradiction result, soak counters if available,
   and a one-line "what breaks if this is wrong".

## Guardrails

- Preamble §3: you touch the blocking lane and `verification/ratified/` ONLY
  through PRs that require the human approval flow. No exceptions for
  "obviously fine" batches.
- Screening evidence is part of the batch PR — an unevidenced promotion is a
  laundering vector even when every test is good.
- Never promote to fill a metric. An empty batch is a valid outcome.

## Bail

Preamble format. Common: corpora too thin to screen (`PROD_REFACTOR_CORPUS`
< 5 commits — floor fixed by design — or a capability with no katas) → the bail names the corpus gap;
building corpus is the prerequisite task, not a reason to skip screening.
