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
- Skill weight (SKILL.md + files it orders read first): prod-new 258 KB, prod-bootstrap 80 KB (74 KB was a recon error),
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
| 0.1 | Runner, host adapters, stub host, report, lint, selftest, `make eval` | Sonnet | `benchmarks/eval/{run.sh,hosts,lib,report.py,lint.sh,selftest.sh,README.md}`, `Makefile` | delivered → Opus NO-OK → fixes in progress |
| 0.2 | prod-review corpus: 6 tasks (4 seeded bugs, 2 clean), 2 held-out | Sonnet | `benchmarks/eval/corpus/prod-review/**` | delivered → Opus NO-OK → fixes in progress |
| 0.3 | Opus validation of 0.1 + 0.2 | Opus | read-only | round 1: NO-OK (below); round 2 pending |
| 3.1 | `skill-weight` gate: 500-line cap, eager-context ratchet (+5 %), 64 KB ceiling with expiring waivers | Sonnet | `_shared/probes/skill-weight*.sh`, `benchmarks/skill-weight-baseline.md`, `registries/waivers.yaml`, wiring | in progress (branch `budget/skill-weight`, worktree `.wt/weight`) |
| 0.4 | Live pilot prod-review, both hosts, n=3 | orchestrator | `benchmarks/eval/results/` | pending |

### Opus validation round 1 of the eval harness — NO-OK (2026-11-27)

Worktree `.wt/eval`, branch `eval/harness`, nothing committed. Confirmed good: all 4 seeded defects
are real; Wilson/Newcombe numbers match an independent computation; `make eval` 18.5 s.
Blockers, all biasing the A/B against the skill or leaking the answer key:
1. Grader counted only lines starting with `path:line`; the skill's native `where: f.go:67` block
   and seven other realistic shapes scored zero.
2. Fixtures lacked the resolved-context artifact the skill requires → a faithful skill arm bails.
3. Clean tasks counted MISSING-TESTS citations (which the skill always emits) as false positives.
4. `clean-01-retry-backoff` had a real defect (`wait(0)` exceeds `MaxDelay`).
5. Host adapters inherited the caller's whole environment (repo path via `OLDPWD`, session
   credentials); Claude ran with `bypassPermissions`, Codex with `workspace-write`.
Also: 9 of 19 validator mutations stayed green (no adapter tests, no grader-rule tests); intervals
treated reps as independent; copying Codex `auth.json` can rotate the refresh token.

Decisions taken for round 2:
- `task.json` gains `agent_mode: read-only|workspace-write`; Claude maps it to a tool allowlist
  (no OS sandbox on Claude — documented asymmetry), Codex to `-s workspace-write` on the workdir.
- Hosts run under `env -i` with one shared allowlist; per-cell GOCACHE; no network for Go.
- Auth: exported token/API key first; keychain / `auth.json` copy only as fallback, with
  write-back on rotation and unconditional scrubbing.
- Verdict from a task-clustered paired bootstrap; fewer than 5 paired tasks → `insufficient tasks`.
  **Consequence: 2 held-out prod-review tasks cannot support a verdict. Corpus must reach ≥ 5
  held-out tasks per skill before the eval gates merges.**
- Cost per resolved task = total spend ÷ resolved count (failed attempts count).
- Grader extracts citations anywhere and classifies DEFECT vs NON-DEFECT; fixtures ship the
  context artifacts to both arms.

### Findings to act on (not yet scheduled)

- `make check-fast` takes ~100 s here (RUNBOOK claims 10 s); the pre-commit hook runs it on every
  commit. Close to the 2-minute rule.
- The gate needs `actionlint` v1.7.7 and PyYAML 6.0.2; neither was installed on this machine.
  Local copies live in `~/.cache/production-skills-tools/venv` and `$(go env GOPATH)/bin`.
- Codex discovers skills at `.agents/skills` / `~/.agents/skills` per the docs, `$CODEX_HOME/skills`
  per the binary. The harness installs to the latter: verify discovery in the first live run
  before trusting any Codex number. See `notes/hosts-research-2026-11-27.md`.
- `prod-validator` has no Edit/Write tools; it ran every mutation on a scratch copy, tree left clean.

### Open / blocked

- Unknown from the Codex binary, to resolve from official docs in Phase 4: agent-role TOML schema,
  `skills.config` keys, hook stdin JSON contract.
- Not yet verified: whether `skill-optimizer run` works with the current Codex auth.
- Nothing is blocked on human input right now.

### Queue (next iterations)

1. Phase 0: corpora for prod-implement, prod-spec, prod-new, prod-bootstrap, prod-test-synth,
   prod-incident, prod-ops, prod-curate. Retire the stale skill-optimizer presentation in README.
2. Phase 3 quick win: prod-new read-first set 258 KB → bounded pulls; SKILL.md body + read-first
   size gate; wire token-report.
3. Phase 4: `_shared/hosts.md`, dual installer, host-vocabulary probe, per-host smoke.
4. Phase 1: greenfield concept in prod-spec, monorepo + React + DS + Playwright template, dim 28.
5. Phase 2: papers loop.
