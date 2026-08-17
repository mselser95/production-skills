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
Maintain both: every sweep, add newly-identified refactor commits and any kata
gap you found. A stale corpus screens nothing.

## Algorithm — test promotion (batch)

1. **Collect eligibles:** candidate-lane tests inside their TTL that have run
   ≥ `PROD_MIN_ADVISORY_RUNS` times with a stable record, `pinning: false`.
2. **Change-detector screening:** run each against every commit in the
   refactor corpus. A test that fails on ANY behavior-preserving commit is a
   change detector → reject, note the commit that caught it.
3. **Mutant-utility dedup:** run the mutation set with blocking lane alone,
   then blocking + candidate. A candidate that kills no mutant the blocking
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

1. Collect candidates (from prod-spec plans, prod-incident packages,
   counterexample-search runs).
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
< 5 commits or a capability with no katas) → the bail names the corpus gap;
building corpus is the prerequisite task, not a reason to skip screening.
