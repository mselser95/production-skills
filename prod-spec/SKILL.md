---
name: prod-spec
description: >
  Orchestrator skill: turn an engineering intent ("add support for X") into a
  resolved context (~30 lines) and a change plan, against the repo's production
  spec — WITHOUT writing any code. Reads the service's production.yaml and
  capability declarations, maps the intent to existing capabilities, pulls ALL
  ratified invariants of the touched services (over-inclusion by default),
  derives obligations from capability-class checklists, detects semantic events
  (new dependency/state/effect/schema change), and emits the two artifacts every
  downstream skill consumes. Stops for human approval when tier is 0.
  TRIGGER when: a task is being started against a repo that has a production
  spec ("prepare the context for X", "plan this change", "resolve what
  implementing X requires", or as the first step of any prod-* pipeline).
  DO NOT TRIGGER when: the user wants code written (that is prod-implement,
  after this skill has run), wants a PR reviewed (prod-review), or the repo has
  no production spec at all (bail: the spec-lite file is a prerequisite).
---

# prod-spec — from intent to contract

Read `references/preamble.md` first. Output formats:
`references/resolved-context.md` and `references/change-plan.md`.

**This skill writes no code.** Its entire value is that everything downstream
becomes cheap because the ambiguity was resolved here, once, by the expensive
model. If you find yourself sketching implementation, stop — that goes in the
plan's task list for `prod-implement`.

## Contract

- **Input:** the task intent (free text), the target repo checkout, and the
  repo's spec (`PROD_SPEC_FILE` in `config.sh`, default `production.yaml`)
  plus its capability files.
- **Output:** `resolved-context.yaml` + `change-plan.yaml` in the task
  workspace (`PROD_CONTEXT_DIR`), in the exact formats referenced above.
  Nothing else.

## Algorithm

1. **Read the spec, not the org policy.** Load `production.yaml`
   (`{tier, invariants[], capabilities[]}`); in v0 the capability entries live
   INLINE in that file — a separate capabilities directory is a later
   hardening, not an assumption. If the repo has a context script
   (`PROD_CONTEXT_CMD`), run it and consume its JSON instead of parsing YAML
   yourself.
2. **Map intent → capabilities, existing first.** The question is "which
   declared capability does this touch?", not "what new thing do I build?".
   Only when no declared capability fits, mark `declared: NEW` — that is a
   semantic declaration and a human moment; say so explicitly in the output.
3. **Pull invariants with over-inclusion.** List ALL ratified invariants of
   every touched service. You do not narrow. If you believe an invariant is
   irrelevant, note it as a comment; narrowing is a human's call.
4. **Derive obligations from class checklists.** For each touched capability,
   copy the obligations its class implies (external_effect ⇒ timeout, retry
   policy, failure model, ambiguous-outcome scenarios, observability;
   source_of_truth ⇒ recovery, reconciliation, backup semantics;
   event_consumer ⇒ duplicate/reorder/poison handling; external_read ⇒
   declared staleness bound, staleness observable, unavailability fallback,
   timeout; connection ⇒ reconnect/sequence-gap/resubscribe). You derive; you never invent or skip.
5. **Detect semantic events** in what the task will require:
   `introduces_dependency`, `introduces_state`, `introduces_external_effect`,
   `introduces_retry`, `introduces_queue`, `introduces_background_worker`,
   `changes_schema`, `changes_public_api`, `changes_hot_path`,
   `changes_critical_calculation`. Each event pulls its requirement set into
   `required_evidence`.
6. **Write the change plan.** Decompose into bounded tasks, each tagged with
   `ambiguity: none|low|open`. Anything `open` stays with the orchestrator
   tier — never hand an open design question to a cheap implementer. New
   states must each have a filled `recovery` block; new dependencies must have
   the full class checklist.
7. **Candidate invariants.** If the change implies a new guarantee, propose it
   in `candidate_invariants` with how it could be falsified. It goes to
   ratification via `prod-curate` — write the package into
   `PROD_RATIFY_QUEUE_DIR` (default `.prod/ratify-queue/`), never into the
   blocking lane from here.
8. **Stop at the human moment.** If `tier == 0`, present the resolved context
   (it fits on one screen — that is the point) and wait for approval before
   any downstream skill runs. Record the approval in the artifact.

## Guardrails

- Preamble rules apply in full; the ones that bite here:
  - You resolve NOTHING by precedent-guessing between policy files (§1).
  - A capability that "seems like it doesn't need reconciliation" still gets
    the obligation; propose a waiver if you disagree (§2).
- Your interpretation is a **hint, not authority**: `prod-review` will
  recompute obligations from the actual diff and fail on divergence. Optimize
  for being auditable, not persuasive.
- Ask, don't guess: if the intent is ambiguous in a way that changes the
  capability mapping or the tier, ask the human ONE precise question rather
  than producing a confident wrong contract. A wrong resolved context is worse
  than no framework — it stamps wrong work with institutional evidence.

## Bail

Use the preamble's BAIL format. Mandatory bails:
- No `production.yaml` in the repo → bail with the minimal spec-lite the repo
  owner must add (`{tier, invariants: [], capabilities: []}`).
- Intent requires a capability class that does not exist in the org vocabulary
  → bail proposing the class, do not improvise one.
