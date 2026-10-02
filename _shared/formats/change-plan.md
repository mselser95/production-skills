# Format: change plan

The decomposition of a task into implementable units. Produced by `prod-spec`
after the resolved context; consumed by `prod-implement` (one task at a time)
and by `prod-review` (to diff claimed-vs-actual). Validated BEFORE code is
generated — a wrong plan is much cheaper to fix than a wrong implementation.

```yaml
# change-plan.yaml
context: <path to resolved-context.yaml>

semantic_events:                  # what kind of change this is — drives obligations
  - introduces_dependency | introduces_state | introduces_external_effect |
    introduces_retry | introduces_queue | introduces_background_worker |
    changes_schema | changes_public_api | changes_hot_path |
    changes_critical_calculation | none

files:
  - path: <file>
    action: create|modify
    zone: core|orchestration|shell   # the three architectural zones

new_states: [<STATE>, ...]           # each new state must answer, in `recovery`:
new_effects: [<effect>, ...]
new_dependencies: [<dep>, ...]       # each requires: timeout, retry policy,
                                     # failure model, observability (class checklist)

recovery:                            # for every new state/effect
  - state: <STATE>
    crash_here: <what restart does>
    retry: idempotent|guarded|forbidden
    reconciled_by: <mechanism>

observability:
  - <new metric/trace attribute/event that makes the change distinguishable in prod>

compatibility:
  schema: unchanged|expand|contract   # contract ⇒ separate later PR, N-1 verified
  api: unchanged|additive|breaking

candidate_invariants:                # proposals only — go to ratification, never
  - statement: <text>                # directly into the blocking lane
    evidence: <how prod-spec believes it could be falsified>

tasks:                               # the implementable units, each bounded
  - id: T1
    kind: implement | acceptance-author   # acceptance-author tasks come first,
                                     # go to prod-acceptance-author, ~8 cases each
    summary: <one sentence>
    files: [<subset of files>]       # small: one concern, ~3 files or fewer
    context: [<ids>]                 # ONLY the invariants, constraints and
                                     # obligations whose scope meets `files` —
                                     # the dispatch sends these, nothing else
    focus: <one question this task must answer about the code>
                                     # what FOCUSED-READ reads against; the
                                     # task is dispatched with its entry
                                     # (see dispatch.md)
    ambiguity: none|low|open         # `open` ⇒ route back to orchestrator, not
                                     # to a cheap implementer
    acceptance: [AC-ids]             # implement: the cases this task turns
                                     # green · acceptance-author: the cases it
                                     # writes · spec: acceptance/<feature>.yaml
    depends_on: []                   # empty + disjoint `files` ⇒ dispatchable
                                     # in parallel
```

**Task size is a token and speed budget.** Each task runs in a FRESH
implementer agent whose every turn re-reads its whole context, so cost grows
with turns × context: a small task converges in a few cheap-gate loops, fails
cheaply, and runs in parallel with its independent siblings. Measured
2026-10-02 over 69 implementer runs: the multi-task runs were 64% of all
implementer tokens, and a context reset per task cut the total by 53%. A task
that needs more than ~3 files or two concerns is two tasks.

Routing rule (from the framework): **ambiguity picks the model; tier picks the
human.** A task with `ambiguity: none` is cheap-model work regardless of tier.
