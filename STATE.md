# STATE — long-running goal (branch `goal/state`, never merged to master)

Orchestrator: Fable. Implementers: Sonnet (`prod-implementer`). Validator: Opus (`prod-validator`).
One idea = one branch off master = one PR. This file lives only on `goal/state`.

## Iteration 1 — started 2026-11-27 — OPEN

### Baseline facts (recon 2026-11-27, master 9532628)

- Hosts: `claude` and `codex-cli 0.172.0` both run headless here. Codex auth works (real
  `codex exec` answered). Both report token usage (`claude -p --output-format json` → `usage`,
  `total_cost_usd`; `codex exec --json` → `turn.completed.usage`).
- User host config is contaminated for eval purposes (`~/.codex/skills`, `~/.codex/AGENTS.md`
  point at unrelated standards). Every eval run uses an isolated temp home per host.
- One trivial `claude -p` turn on Fable cost USD 0.41 (cache creation). Eval subjects run on
  Sonnet with a per-run budget cap.
- No benchmark score exists in the repo (no `benchmark-results/`, no `report.json`). The
  `skill-optimizer` configs date from 2026-08-17 and were never re-run.
- Skill weight (SKILL.md + files it orders read first): prod-new 258 KB, prod-bootstrap 74 KB,
  prod-review 41 KB, prod-spec 31 KB, prod-implement 29 KB, others 21–26 KB. No gate reads
  SKILL.md body size or read-first size. `token-report.sh` is wired to no gate.
- Host vocabulary: zero Claude-specific terms in the nine SKILL.md (frontmatter is `name` +
  `description`, which Codex accepts). Host coupling sits in `install.sh`, `agents/*.md`
  (`model`, `tools`), `_shared/dispatch.md`, `_shared/hooks/agent-dispatch-guard.sh`.
- `install.sh` does not install `_shared/hooks/` nor register them: the dispatch guard is a
  manual step on Claude Code too.
- prod-new: Go only, single service repo, no frontend/monorepo/pnpm/Playwright anywhere.
  prod-spec has no greenfield concept. Next free dimension: 28.
- Design-system yardstick: 5 packages, 24 components, 3-layer tokens (~240 leaves), vanilla-extract
  theme contract, Storybook 10 docs with contrast + story-coverage tests, changesets. 513 brand
  mentions → written fresh, same shape; never copied and scrubbed.
- No workflow has `timeout-minutes` (finding; conflicts with the 2-minute rule).
- `prod-validator` has no Edit/Write but claims revert-able mutations (via Bash). To verify.

### Phase 0 contract — eval harness (`benchmarks/eval/`)

Question answered: does the skill produce better output than the same agent without it?

Layout
```
benchmarks/eval/
  README.md                 method, how to add a task, how to read a report
  run.sh                    one cell: (task, arm, host, rep) → one JSONL row
  hosts/{claude,codex,stub}.sh   host adapters, one contract
  lib/                      shared helpers
  report.py                 JSONL → table (python3 stdlib only)
  lint.sh                   corpus lint: every grader RED on unsolved, GREEN on reference
  selftest.sh               hermetic, stub host, no network, < 60 s
  corpus/<skill>/<task-id>/ task.yaml, fixture/, grade.sh, reference/
  results/                  committed live results: <date>-<skill-sha>.jsonl + .md
```

Task (`task.json`; JSON because PyYAML is not a dependency here): `id`, `skill`, `split: dev|heldout`, `prompt` (host-neutral, never names the
skill), `timeout_s`, `max_budget_usd`, optional `setup` (script run in the workdir before the agent).
The agent sees ONLY a copy of `fixture/` (git-initialised). `grade.sh` and `reference/` never enter
the workdir: hidden tests stay hidden.

Arms: `skill` (the skill installed in the isolated host home; the runner appends one line asking
to use it) vs `bare` (same prompt, same model, nothing installed).

Grader: `grade.sh <workdir> <agent-output-file>` → exit 0 pass / 1 fail / 2 grader error, and one
JSON line on stdout with task-specific metrics (`found`, `missed`, `false_positives`, ...).
Deterministic. No LLM judge in iteration 1.

Result row: `task, skill, split, arm, host, model, rep, pass, metrics, tokens_in, tokens_out,
cost_usd, duration_s, exit, skill_sha, harness_sha, ts`.

Report per (skill, host, arm): success rate with Wilson 95 % interval, pass^k, mean tokens and
seconds per RESOLVED task, false positives; and the skill−bare delta with its interval. Held-out
reported separately and never used to tune.

Gates
- `make eval` (CI, hermetic, < 2 min): `selftest.sh` + `lint.sh`. No credentials needed.
- `make eval-live` (local, explicit, outside CI): real runs; results committed.
- Non-vacuity: a sabotaged skill must score worse on live runs; a sabotaged grader/runner must
  turn `selftest.sh` red.

### Work log

| # | Task | Owner | Paths | Status |
|---|------|-------|-------|--------|
| 0.1 | Runner, host adapters, stub host, report, lint, selftest, `make eval` | Sonnet | `benchmarks/eval/{run.sh,hosts,lib,report.py,lint.sh,selftest.sh,README.md}`, `Makefile` | dispatched |
| 0.2 | prod-review corpus: 6 tasks (4 seeded bugs, 2 clean), 2 held-out | Sonnet | `benchmarks/eval/corpus/prod-review/**` | dispatched |
| 0.3 | Opus validation of 0.1 + 0.2 | Opus | read-only | pending |
| 0.4 | Live pilot prod-review, both hosts, n=3 | orchestrator | `benchmarks/eval/results/` | pending |

### Open / blocked

- Unknown from the Codex binary, to resolve from official docs in Phase 4: agent-role TOML schema,
  `skills.config` keys, hook stdin JSON contract.
- Not yet verified: whether `skill-optimizer run` works with the current Codex auth.

### Queue (next iterations)

1. Phase 0: corpora for prod-implement, prod-spec, prod-new, prod-bootstrap, prod-test-synth,
   prod-incident, prod-ops, prod-curate. Retire the stale skill-optimizer presentation in README.
2. Phase 3 quick win: prod-new read-first set 258 KB → bounded pulls; SKILL.md body + read-first
   size gate; wire token-report.
3. Phase 4: `_shared/hosts.md`, dual installer, host-vocabulary probe, per-host smoke.
4. Phase 1: greenfield concept in prod-spec, monorepo + React + DS + Playwright template, dim 28.
5. Phase 2: papers loop.
