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
| Greenfield four questions + slot instantiation (`prod-new`) | main session | session model | inline |
| Greenfield template body generation (large scaffold builds) | `prod-implementer` agent | sonnet | Agent tool |
| Review judgment: divergence, calibration, verdicts (`prod-review` phases 1–5) | main session | session model | inline |
| Incident analysis + invariant candidates (`prod-incident` steps 2–5) | main session | session model | inline |
| Ratification packages, screening interpretation (`prod-curate` judgment) | main session | session model | inline |
| Repo inventories, recon sweeps, full-file reading fan-outs (bootstrap phase 1, review phase 0 on large diffs) | `prod-scout` agent | **haiku** | Agent tool (pinned in frontmatter — omit `model`) |
| One bounded change-plan task (`prod-implement`) | `prod-implementer` agent | **sonnet** — always; haiku measured 2–5× more turns and 2 of 3 NO-OK on closed-contract fixes (2026-10-02) | a FRESH Agent call per task — never one agent looping over the plan, never a fork; independent tasks in parallel |
| Read-only review of one commit/diff after an implementer hands back | `prod-validator` agent | opus | Agent tool, a FRESH call per task |
| Acceptance tests for an APPROVED spec (`kind: acceptance-author` tasks) | `prod-acceptance-author` agent | sonnet | a fresh Agent call per ~8 cases, in parallel, BEFORE any implementation task; never the same agent that implements |
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

## Token and context budget

Measured 2026-10-02 over 672 subagent transcripts: `prod-implementer` was the
largest consumer, 2,865M input tokens over 69 runs. An agent's every turn
re-reads its whole context, so cost is turns × context and both have to stay
small. These rules are what that measurement bought; each names its share.

1. **One fresh agent per task.** 22 of 69 dispatches handed one agent the
   whole plan ("T1..T13 in order"); they were 64% of the total, peaking at
   1,182 turns and 965k tokens of context. Resetting context at each task
   boundary cut the total by 53%. Loop over tasks HERE, in the orchestrator,
   one Agent call each; the implementer bails on a multi-task dispatch.
2. **Never implement in a fork.** A fork inherits the parent's whole context
   (median start 170k tokens, against ~20k for a pinned agent with a
   restricted tool list) and re-reads it every turn.
3. **Send only what is relevant.** The message follows the fixed section
   order in `formats/dispatch-message.md` (static to dynamic, ~1.5k tokens
   at most; a dispatch that needs more is a task that is too big). The
   `focus:` from the change plan travels in section 2 of the message.
4. **Small tasks, run in parallel.** A task that touches more than ~3 files
   or two concerns is split at `prod-spec` time. Tasks with empty
   `depends_on` and disjoint `files` are dispatched together, each with Agent
   `isolation: "worktree"`, and merged in plan order — smaller converges
   faster, fails cheaper, and the wall clock is the slowest task, not the sum.
5. **Model: omit the `model` parameter by default.** The Agent tool's `model`
   overrides the pinned frontmatter: the haiku-pinned scout and mechanic ran 6
   times on sonnet because a dispatch passed one. Do not pass `model: haiku` for implementation; `token-report` keeps BAIL
   rate and turns per model so this can be revisited with data. Pass a more expensive model only with a reason in the message.
6. **No waiting laps, no raw logs.** Agents run gates in the foreground or
   with Bash `run_in_background`, never in `sleep`/`until`/`pgrep` loops (7%
   of implementer Bash calls), pipe gate output through a failure filter and
   `tail`, and prove mutations with `probes/prove-mutation.sh` — one call, one
   line. The orchestrator's `verify-standard` re-verification (Rules, item 5)
   runs once after the plan's last task, not once per task.

## What the evidence says NOT to add

- No critic or planner agents in the loop: they add roughly nothing and cost
  about 1.8x the calls (2609.04217, 2604.02460).
- No learned router: the static table above is the router (2601.07206).
- No LLM summarisation of context: truncate verbatim (CliffCompaction 2609.26779).
- No "write tests" instruction to implementers as a score lever: acceptance
  tests come from `prod-acceptance-author` (2602.07900).
- No visible-oracle-only acceptance: a green gate the agent can see is not
  evidence (2605.21384, 2606.28430).

## Escalation

A cheap agent that bails with `blocked_on: ambiguity|judgment` escalates to
the session model — once. If the session model resolves it, the task is
re-dispatched with the resolution appended to the contract. Two escalations
on one task mean the task was mis-scoped: back to `prod-spec` to re-plan, not
a third attempt.

Loop bail: a `blocked_on: loop` BAIL is re-dispatched ONCE to a fresh agent
with the parked diff as overlay and the loop's command named in the contract;
a second loop on the same task goes back to `prod-spec`.
