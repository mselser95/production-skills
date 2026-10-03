# Dispatch message — fixed section order, static to dynamic

Every Agent dispatch has the same six sections in the same order. Static
content goes first so the cached prefix survives from one task to the next;
dynamic content goes last. Never edit or re-send earlier context: a changed
prefix is a cache miss on everything after it (2601.06007), and tool results
belong outside the cached prefix. Switching models mid-session forfeits the
prefix too (2607.19214), so never pass `model:` unless the message states the
reason (see `dispatch.md`).

1. **Role line** — one line naming the agent role and that it does ONE task.
2. **Task contract** — task id, one-sentence summary, `kind:`, `focus:` (carried
   verbatim from the change plan), `files:`, `acceptance:` ids.
3. **Resolved context** — only the entries named by the task's `context:`
   ids, quoted verbatim. Not the whole plan, other tasks, earlier reports,
   review history, or file contents the agent can read itself.
4. **Mask and gates** — `do_not_touch` paths and the gate commands.
5. **Output format and bail conditions** — the evidence block and the BAIL
   block, with `blocked_on` values.
6. **Artifact paths LAST** — paths to the full plan/context, for checking a
   reference only.

Budget: at most ~1.5k tokens. A dispatch that needs more is a task too big;
split it at `prod-spec` time.

## Worked example

```
You are prod-implementer. Do ONE task; if more than one is named, BAIL multi-task-dispatch.

## Task
id: T4 — reject empty `tenant_id` in the quote handler
kind: implement
focus: where does the handler validate input, and what happens on a malformed tenant_id field?
files: src/quote/handler.go, src/quote/handler_test.go
acceptance: AC-12, AC-13

## Context (quoted)
C3 (invariant, ratified): a quote request without tenant_id is never priced.
C7 (obligation): every new reject branch increments quote_rejected_total{reason}.

## Mask and gates
do_not_touch: verification/ratified/**, .github/**, registries/**
cheap gate: make check-fast (max 5 iterations)

## Output and bail
IMPLEMENTED / sha / files / gate last lines / deviations.
BAIL: task, progress, blocked_on (iteration-cap|tcb:<artifact>|existing-test|
ambiguity|multi-task-dispatch), tried, state.

## Artifacts (read only if a reference must be checked)
.prod/context.md, .prod/plan.md
```
