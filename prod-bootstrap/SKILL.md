---
name: prod-bootstrap
description: >
  Interactive onboarding skill: bring a repo "to standard" — inventory it
  against the production-verifiability framework, ask the human the semantic
  questions only they can answer (tier, capabilities and their classes, seed
  invariants, source of truth, latency budget, gate commands), then scaffold
  the spec and directories, emit an honest gap report (requirement → current
  state → severity), and produce a RATCHET-style refactor plan in change-plan
  format — bounded tasks routed to prod-implement, never a big-bang rewrite.
  The human is present and answering throughout; this is the one skill in the
  suite that is conversation-first.
  TRIGGER when: a repo is being onboarded to the standard ("bootstrap this
  repo", "bring X to standard", "set up production.yaml for this service",
  "what does this repo need to comply?"), for greenfield and brownfield alike.
  DO NOT TRIGGER when: the repo already has a production spec and the ask is a
  task against it (prod-spec), or the context is headless (CI, cron,
  non-interactive runs) — the Q&A requires a present human; bail instead of
  guessing semantic answers.
---

# prod-bootstrap — bring a repo to standard

Read `references/preamble.md` first. Outputs use
`references/resolved-context.md` conventions for the spec fields and
`references/change-plan.md` for the refactor plan. Registry and path names
come from `config.sh`.

Two rules frame everything:

- **Semantic facts come from the human, never from inference.** You may
  PROPOSE (detected boundaries, suggested classes, candidate invariants);
  the human ratifies each one. A bootstrap that guesses the tier or invents
  capability semantics produces a wrong contract with institutional
  authority — worse than no spec.
- **The plan is a ratchet, never a rewrite.** Brownfield repos get compliant
  at the frontier (new/changed code) plus a leverage-ordered backlog; nothing
  in the plan blocks current work on day one.

## Contract

- **Input:** the target repo checkout + a present human.
- **Output:**
  1. `production.yaml` (spec-lite: `{tier, invariants[], capabilities[]}`),
     each entry human-ratified;
  2. scaffolded directories: `verification/ratified/` (empty skeleton +
     README), `<PROD_REGRESSIONS_DIR>/`, `PROD_RATIFY_QUEUE_DIR`, the
     liability registries (empty, with headers);
  2b. the repo's **`AGENTS.md`** instantiated from
     `references/agents-template.md` — the routing contract that makes EVERY
     future agent request in this repo pass through the pipeline
     (spec → implement → review) and validate against the standard; merged,
     never overwritten, if one already exists;
  3. the **gap report** (format below);
  4. the **refactor plan** in change-plan format, tasks tagged
     `ambiguity: none|low|open`, ordered by leverage;
  5. per-skill `config.sh` value suggestions for this repo (gate commands,
     paths) — printed, not written to skill dirs.

## Algorithm

Dispatch per `references/dispatch.md`: Phase 1 runs on a `prod-scout` agent
(cheap, read-only, checklist in / facts report out); phases 2–5 stay on the
session model with the human.

### Phase 1 — Inventory (read-only, no questions yet)
Detect and record, without judging:
- language/build layout; entrypoints; package structure vs the three zones
  (is there a pure core? where does I/O live?);
- external boundaries: every outbound client, DB, queue, stream, scheduler
  found in the code — each is a CANDIDATE capability with a guessed class;
- existing spec artifacts (`PROD_SPEC_FILE`?), test layout (any provenance
  convention? any advisory lane?), CI stages (is there a cheap gate? what
  runs on PR vs nightly?), fitness checks (import bans, forbidden calls),
  clock/random/ID injection vs direct calls in core paths, outbox/journal
  patterns on external effects, reconciliation jobs, registries.

### Phase 2 — The Q&A (one question at a time, propose-then-ratify)
Ask ONLY what cannot be derived; propose a default with evidence for each:
1. **Tier** — propose from consequence ("this service moves X / stores Y;
   irreversible effects found at Z ⇒ T0?"); human decides.
2. **Capabilities** — walk the candidate list from Phase 1 one by one:
   confirm/rename, assign class (external_effect / source_of_truth /
   event_consumer / external_read / connection), and for each class ask its
   semantic facts (ambiguous outcome possible? duplicates possible? staleness
   bound? source of truth for what?). Detected-but-declined candidates are
   recorded as explicitly out of scope.
3. **Seed invariants** — ask the domain question directly: "what must never
   happen in this system?" Convert each answer to a falsifiable statement;
   these become candidate invariants in `PROD_RATIFY_QUEUE_DIR` (ratification
   is its own moment — bootstrap never writes `verification/ratified/`).
4. **Hot path** — is there a latency budget that excludes durable
   orchestration? Where does it run?
5. **Commands** — the cheap gate and presubmit commands for this repo.

### Phase 3 — Scaffold
Write the spec, directories, and the AGENTS.md routing contract (Contract
output 1–2b) — every `<slot>` in the template filled from a ratified Phase-2
answer, per the template's instantiation rules. Everything written is
additive — bootstrap never edits existing code, tests, or CI config
(preamble §3 applies; CI wiring for new lanes is a plan task for a human or
prod-implement under review, not a bootstrap side effect).

### Phase 4 — Gap report
One row per standard requirement, honest and complete:

```
GAP REPORT — <repo> (tier T<k>)
| requirement | current state | gap | severity |
```
Cover at minimum: spec present; zones separation; fitness checks; clock/rand
injection; provenance lanes; cheap gate; incident fixtures dir; registries;
invariants ratified; reconciliation; observability of critical transitions.
Severity is impact-based (a T0 repo without invariants outranks a missing
registry). No row is omitted because it is embarrassing.

### Phase 5 — Refactor plan (the ratchet)
Emit change-plan tasks ordered by leverage, each bounded and routable:
1. fitness checks (import bans, forbidden calls in core) — days of work,
   permanent payoff, zero behavior change;
2. clock/random/ID injection on critical paths;
3. extract the first pure decision core (the highest-risk calculation);
4. outbox/journal on external effects + table-driven recovery tests;
5. provenance headers + advisory lane wiring;
6. seed the incident-fixture corpus from the last known incidents;
7. reconciliation job for the primary source-of-truth pair;
8. fuzz targets on every decode/parse boundary (checked-in seed corpus,
   wired into the repo's fuzz lane);
9. mutation advisory baseline over the core packages (TREND, never a gate);
10. benchmark baseline of the hot path with a versioned workload (relative
    regression only — SIGNAL).
This list is the MINIMUM: a plan that omits any dimension without an
explicit declined-with-rationale entry is an incomplete bootstrap — the
human should never have to ask "where is the fuzzing?". Tasks a cheap model
can do are tagged `ambiguity: none` and handed to `prod-implement`; design
decisions stay `open` with the human. State explicitly which gaps the plan
does NOT cover and why.

## Guardrails

- Preamble in full. Bootstrap-specific:
  - Every semantic fact in the spec traces to a human answer from Phase 2 —
    the artifact records ratification, like a resolved context does.
  - Never block the repo's current work: nothing in the scaffold turns any
    existing check red on day one; new gates arrive via the plan, warn-first.
  - If the human is absent or answers stall, park everything produced so far
    in a branch and BAIL with state — a half-ratified spec is not a spec.

## Bail

Preamble format. Expected `blocked_on` values: `headless` (no human present —
this skill never guesses semantics), `spec-exists` (repo already has one —
point to prod-spec), `answers-stalled`.
