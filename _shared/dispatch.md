# Dispatch — how the arbitrage actually runs

The framework's economics ("expensive models orchestrate, cheap models
implement, the verifier decides") is operational, not aspirational. This file
is the routing table every orchestrator skill applies: **the session model
thinks; pinned cheap agents execute.** An orchestrator skill that does
mechanical work inline is spending flagship tokens on haiku work — that is a
dispatch bug.

## The routing table

| Work | Who runs it | Model | Mechanism |
|---|---|---|---|
| Intent interpretation, resolved context, change plan (`prod-spec`) | main session | the user's session model (expensive) | inline |
| Bootstrap Q&A + synthesis (`prod-bootstrap` phases 2–5) | main session | session model | inline |
| Review judgment: divergence, calibration, verdicts (`prod-review` phases 1–5) | main session | session model | inline |
| Incident analysis + invariant candidates (`prod-incident` steps 2–5) | main session | session model | inline |
| Ratification packages, screening interpretation (`prod-curate` judgment) | main session | session model | inline |
| Repo inventories, recon sweeps, full-file reading fan-outs (bootstrap phase 1, review phase 0 on large diffs) | `prod-scout` agent | **haiku** | Agent tool, `model: haiku` |
| One bounded change-plan task (`prod-implement`) | `prod-implementer` agent | **sonnet** (drop to haiku when the task is `ambiguity: none` AND touches no T0 path) | Agent tool per task |
| Candidate test generation (`prod-test-synth`) | `prod-implementer` agent | sonnet | Agent tool |
| Bisects, reverts, flake repro, sweeps, rebases (`prod-ops`) | `prod-mechanic` agent | **haiku** | Agent tool |
| Screening runs: refactor-corpus replays, kata runs, mutation dedup (`prod-curate` mechanics) | `prod-mechanic` agent | haiku | Agent tool |
| Batch fan-outs (N candidates × screening, N clauses × synthesis) | workflow of the above | per row above | Workflow tool — only when the user has opted into multi-agent orchestration; otherwise sequential Agent calls |

## Rules

1. **The session model is the user's choice, not the skill's.** Orchestrator
   skills never demand a specific flagship — they demand the SESSION tier.
   Upgrading/downgrading the orchestrator is `/model`, owned by the human.
2. **Cheap agents are pinned in their definitions** (`agents/*.md`
   frontmatter), not chosen per call by the orchestrator's mood. Overriding a
   pinned model UP requires a reason stated in the dispatch message.
3. **Ambiguity picks the model; tier picks the human** (the framework's two
   axes). A T0 task with `ambiguity: none` still runs on a cheap agent —
   the human moment was the resolved context, not the typing.
4. **Dispatch messages are contracts:** a dispatched agent gets the resolved
   context (or checklist), its ONE task, the output format, and its bail
   conditions — never "figure it out". The quality of the dispatch message is
   what makes the cheap model sufficient.
5. **Results come back as data, and claims get probed.** Scouts return
   structured reports; implementers return the IMPLEMENTED evidence block or a
   BAIL; mechanics return operation outputs. The orchestrator synthesizes — it
   never re-does the work, and it never RELAYS a claim as a fact: every
   dimension a dispatch touched is re-verified by the orchestrator with
   `probes/verify-standard.sh` before it appears in any report. Relaying an
   agent's block verbatim is how a no-op port and an empty profiling section
   both shipped as "done".
6. **No recursive expensive spawns.** A cheap agent never spawns another
   agent; if its task needs judgment, it bails back to the orchestrator
   (that IS the routing working).

## Escalation

A cheap agent that bails with `blocked_on: ambiguity|judgment` escalates to
the session model — once. If the session model resolves it, the task is
re-dispatched with the resolution appended to the contract. Two escalations
on one task mean the task was mis-scoped: back to `prod-spec` to re-plan, not
a third attempt.
