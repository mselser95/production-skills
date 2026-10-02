# Format: acceptance spec

The feature's definition of done, written BEFORE any code, as externally
observable behaviour. Produced by `prod-spec` (session model — this is the
thinking step), approved by a human, turned into failing tests by the
`prod-acceptance-author` agent, and made green by `prod-implementer` tasks that
may not edit those tests.

**Acceptance, not unit, not chaos.** Every case is driven through the
service's PUBLIC surface (HTTP/gRPC/WS endpoint, consumed event, CLI command)
and asserts only what a client, a downstream consumer, or an operator could
observe (response, emitted event, persisted state read back through the
surface, metric/log the runbook relies on). A case that names an internal
function, mocks the code under test, or asserts on a private struct is a unit
test in disguise — rewrite it at the boundary. Real dependencies where the
repo's integration lane provides them; a fake only for a third party outside
the org, and then the fake is the contract fixture, not an inline stub.

**Unpleasantly comprehensive is mechanical, not inspired.** Comprehensiveness
comes from the matrix below: every cell is filled with case ids or with
`na:` and a reason a reviewer can disagree with. An empty cell, or `na` with
no reason, fails `acceptance-coverage.sh`. The matrix is what stops "I covered
the happy path and two errors" from reading as done.

```yaml
# acceptance/<feature>.yaml   (versioned WITH the tests, not in .prod/)
feature: <kebab-name>                  # the id prefix tests cite
intent: <one sentence, the resolved-context task>
approved_by: pending | <human>         # the human moment; tests are written
approved_at: <date>                    #   only after this is not `pending`
surface:                               # the public entrypoints exercised
  - <POST /v1/transfers | grpc Ledger.Credit | event deposits.v1 | ...>

matrix:                                # EVERY key, each: [AC-ids] or {na: <reason>}
  happy_path:            [AC-01]       # each operation's main success, end to end
  input_classes:         [AC-02, ...]  # per input field: valid, boundary, empty,
                                       #   malformed, oversized, wrong type/unit
  declared_errors:       [...]         # every error the contract declares, each
                                       #   with its DISTINGUISHABLE signal
  authorization:         [...]         # who may, who may not, cross-tenant
  idempotency_retry:     [...]         # same request twice, retry after timeout,
                                       #   ambiguous outcome
  state_transitions:     [...]         # every state × operation, incl. illegal ones
  ordering_concurrency:  [...]         # as a client sees it: races, reordering,
                                       #   duplicate delivery
  durability_restart:    [...]         # survives restart / redeploy mid-operation
  compatibility:         [...]         # old clients, old data, old events
  feature_interaction:   [...]         # what neighbouring features must still do
  observability:         [...]         # the signal an operator needs to tell this
                                       #   feature's failure apart from others

cases:
  - id: AC-01
    given: <state, set up through the surface or the fixture corpus>
    when: <one action on the surface>
    then: <the observable outcome, exact enough to assert>
    observe: response | event | readback | metric | log
    mutation: <the one code change that must turn this RED — e.g. "skip the
               balance check in the transfer handler">
```

## Rules

- **Ids** are `AC-NN`, unique in the file. Tests cite them as
  `acceptance:<feature>/AC-NN` in the provenance header (`provenance:
  derived` — the approved spec is the clause), one or more tests per case.
- **`mutation:` is mandatory.** It is how the author proves the test has
  teeth (`probes/prove-mutation.sh`, RED required) and how review spots a case
  whose oracle could not fail. "Return an error" is not a mutation; name the
  line of behaviour that breaks.
- **Approval is always required**, whatever the tier. The spec is one line
  per case and reads in minutes; it is the cheapest place a human can say
  "that is not what I meant", and after approval it is the oracle the
  implementer cannot argue with.
- **Changing an approved spec** is a new approval. An implementer that finds a
  case wrong BAILs (`blocked_on: acceptance-case:<id>`); it never edits the
  case or its test.
- **Size.** Author dispatches carry ~8 cases each, grouped by matrix row, so
  they run small and in parallel (`references/dispatch.md`).
