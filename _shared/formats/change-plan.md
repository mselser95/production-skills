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
    summary: <one sentence>
    files: [<subset of files>]
    ambiguity: none|low|open         # `open` ⇒ route back to orchestrator, not
                                     # to a cheap implementer
    depends_on: []
```

Routing rule (from the framework): **ambiguity picks the model; tier picks the
human.** A task with `ambiguity: none` is cheap-model work regardless of tier.
