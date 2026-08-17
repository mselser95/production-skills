# Format: resolved context

The ~30-line contract a task is executed against. Produced by `prod-spec`,
consumed by `prod-implement` and `prod-review`, approved by a human when
`tier: 0`. This is the single cheapest, highest-leverage human gate in the
system — keep it short enough that a human actually reads it.

Rules:

- **Over-inclusion by default.** All ratified invariants of the touched
  service(s) are listed and run. NARROWING the list is the operation that
  needs human approval, not expanding it.
- The `do_not_touch` block always names the TCB paths.
- Nothing in this file is free prose except `task`.

```yaml
# resolved-context.yaml
task: <one sentence, the intent as interpreted>
tier: 0|1|2
services: [<service>, ...]

capabilities:
  touched:
    - id: <capability-id>          # must exist in the service spec, or be
      class: <external_effect|source_of_truth|event_consumer|external_read|connection>
      declared: existing|NEW       # NEW ⇒ a semantic declaration (human moment b)
  obligations:                     # derived from class checklists, never invented
    - <obligation-id>: <what evidence satisfies it>

invariants:                        # ALL ratified invariants of the touched services
  - <invariant-id>                 # names resolve to code symbols; a broken name is a build break

required_evidence:
  gates: [<the deterministic checks that must be green>]
  signals: [<what goes to review: surviving mutants, coverage, bench delta>]

constraints:
  - <architecture rules in force for the touched paths>

do_not_touch:
  - verification/ratified/**
  - <CI config paths>
  - <registry paths>

approval:                          # present and signed when tier == 0
  approved_by: <human>
  date: <date>
```
