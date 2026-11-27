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
| 3.1 | `skill-weight` gate: 500-line cap, eager-context ratchet (+5 %), 64 KB ceiling with expiring waivers | Sonnet | `_shared/probes/skill-weight*.sh`, `benchmarks/skill-weight-baseline.md`, `registries/waivers.yaml`, wiring | delivered → Opus NO-OK → round 2 in progress (branch `budget/skill-weight`, worktree `.wt/weight`) |
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

### Eval harness — Opus rounds 2 and 3, and the redesign (2026-11-27)

Round 2 (CHANGES REQUIRED): round-1 blockers closed; new ones — lazy/shotgun reviews earned
credit, a faithful skill review failed clean-01, Claude "read-only" could run arbitrary programs,
2 held-out tasks could not support a verdict. Fixed: seatbelt write confinement, corpus grown to
12 tasks (6 dev / 6 held-out), two-level bootstrap, Linux-portable hermetic gate wired in CI.
Paid probes (haiku, < USD 0.01 each) then exposed three more grader rules that real output broke.

Round 3 (CHANGES REQUIRED), fresh validator:
- The prose grader agreed with hand labels on only 20 of 37 realistic reviews (54 %), in patterned
  ways (lowercase labels after a citation, neutral sub-headings, findings under "Summary", the
  skill's own WARNING = "smell" convention).
- The answer key was reachable inside the sandbox (repo `.git` object store, other copies, the
  profile file in the agent's home); the secret deny-list missed `~/.claude-*`, the docker socket
  and more; Codex's own sandbox does not restrict reads.
- Two authors' context artifacts were inconsistent, failing a faithful skill review on clean-01.
- Good: all 12 tasks hold (4 new defects reproduced, no defect found in any clean task), report
  statistics match an independent recomputation exactly, 27 of 29 mutations RED.

DECISION — stop patching, change the design:
1. **Structured output instead of parsing prose.** The agent must return findings as JSON under a
   schema (`claude --json-schema`, `codex --output-schema`): file, line range, class
   (defect / missing_test / not_validated / note). The grader compares data only; `severity` is
   ignored because WARNING means different things to different reviewers. All heading/label
   heuristics are deleted.
2. **Allowlist sandbox, identical for both hosts.** Deny reads of all of `/Users`, `/tmp`,
   `/var/folders`, docker and agent sockets; re-allow only the cell's dirs and the tool install
   roots. Codex runs inside the same `sandbox-exec` profile with its own sandbox disabled.
3. **Two verdicts, never pooled:** recall on seeded tasks and false-positive rate on clean tasks.
4. Context artifacts normalised by one rule across all 12 tasks; seeded-vs-clean tells removed.
Lesson recorded: three times a REAL model output broke a rule the synthetic tests called fine.
The pilot therefore includes a calibration step — hand-label real outputs from both arms and both
hosts and report grader agreement — before any number is used to decide a merge.
Status: two fresh Sonnet implementers dispatched (corpus/grader; harness/sandbox). Round 4 next.

### Findings to act on (not yet scheduled)

- `make check-fast` takes ~100 s here (RUNBOOK claims 10 s); the pre-commit hook runs it on every
  commit. Close to the 2-minute rule.
- The gate needs `actionlint` v1.7.7 and PyYAML 6.0.2; neither was installed on this machine.
  Local copies live in `~/.cache/production-skills-tools/venv` and `$(go env GOPATH)/bin`.
- Codex discovers skills at `.agents/skills` / `~/.agents/skills` per the docs, `$CODEX_HOME/skills`
  per the binary. The harness installs to the latter: verify discovery in the first live run
  before trusting any Codex number. See `notes/hosts-research-2026-11-27.md`.
- `prod-validator` has no Edit/Write tools; it ran every mutation on a scratch copy, tree left clean.

### Phase 5 — language portability: Go, Rust and Python (added by the user 2026-11-27)

Everything the skills produce and check must work for Rust and Python services, not only Go.
Today the standard is Go-only in four places (recon 2026-11-27):
- `_shared/probes/verify-standard.sh` (6,332 lines) is a Go-only probe (RUNBOOK.md:8, AGENTS.md:91).
- `prod-new/template/` is Go only (83 `.go` files; `config.example.yml` `PROD_LANGUAGE="go"`).
- `_shared/dimensions.md` and the skills describe mechanisms through Go tooling.
- The eval corpus fixtures and the harness's toolchain env (GOCACHE, GOPROXY) are Go only.

Scope
1. A language-neutral core: each dimension and each verify-standard row states the PROPERTY, and a
   per-language adapter says how it is checked (Go / Rust / Python). A row with no adapter for the
   repo's language is a FAIL or an explicit, dated liability — never a silent NA.
2. prod-new scaffolds a service in any of the three, with the same zones, gates, registries,
   observability and non-vacuity selftests; the monorepo default (Phase 1) accepts any of the three
   as the backend. Default when the human does not say: Go (unchanged). ASSUMPTION — revisit if told.
3. prod-spec, prod-implement, prod-review, prod-test-synth, prod-bootstrap, prod-incident, prod-ops,
   prod-curate: no step may assume Go (test provenance headers, lanes/build tags, mutation, fuzz,
   race detection, coverage, lint, SAST, dependency pinning each need a Rust and a Python form).
4. Eval: every skill's corpus has tasks in all three languages, reported per language; a skill
   "works" for a language only when it wins the held-out there. The harness's isolated toolchain
   env becomes per-language (GOCACHE / CARGO_HOME + target dir / pip + venv caches, all offline).
5. A probe fails when a skill or shared file names one language's tool as THE way to do something
   without the other two (same mutation discipline as the host-vocabulary probe of Phase 4).
Order: after the eval harness lands (it is the measuring stick), start with the corpus in three
languages for prod-review (cheapest, proves the harness), then the adapter split of
verify-standard, then the Rust and Python templates.

### Scope additions by the user, 2026-11-27 (after Phase 5)

- **Frontend is ALWAYS React** (not only the default): React + TypeScript in the pnpm monorepo,
  whatever the backend language. No other frontend framework is scaffolded or supported.
- **Research good AND secure practices for every stack before building its template.** One notes
  file per stack under `notes/`, from primary sources, each practice written as something a gate can
  check: `practices-go.md`, `practices-rust.md`, `practices-python.md`,
  `practices-react-frontend.md`, `practices-postgres-timescale.md`. These are INPUT to the
  templates and to the per-language adapters; a practice enters the standard only with a gate and a
  mutation that turns it red. Status: five research agents dispatched 2026-11-27.

### Phase 6 — databases (added by the user 2026-11-27)

Default database for every scaffolded service: **PostgreSQL 18**. **TimescaleDB on top** when the
service has time-series data. A priori no other store is scaffolded.
Hard requirement: the database is BORN with probing and metrics, so it can be monitored from the
first commit:
1. Init ships: least-privilege roles (owner / migrator / app / read-only / monitoring), secure
   auth + TLS defaults, the statistics extensions and settings needed for monitoring, timeouts.
2. A metrics exporter and liveness/readiness probes for the database wired into the scaffold's
   observability (same registries as the service: emitted metrics, alerts, runbook entries).
3. A must-have metric set (availability, connections, replication lag, WAL/archiving, wraparound
   distance, autovacuum, locks, slow queries, disk growth, backup age; for Timescale: chunks,
   compression backlog, background-job failures, continuous-aggregate lag) with an alert each.
4. A CI test against a throwaway container proving the probes answer and the exporter serves the
   declared metrics after init — so monitoring cannot rot silently — plus a mutation that turns it
   red (drop the monitoring role / disable the extension).
5. Migrations with a safe-DDL linter as a gate, typed queries per backend language, real Postgres
   in tests (no mocks of the database), a restore test.
6. Works for the three backend languages (Phase 5) and is covered by eval corpus tasks.
DECIDED 2026-11-27 (user confirmed): stay on **PostgreSQL 18**, do not move to 19 yet.
- Research says TimescaleDB supports PG 18 from 2.23 (latest seen 2.32.1), PG 19.0 was announced
  2026-11-19, Docker `latest` now points to 19, and Timescale has no official PG 19 support.
  NOT independently verified — confirm against the real images and support matrix before pinning.
- The scaffold pins PG minor + Timescale version as ONE tested pair in a single place, by digest,
  never `latest` (2.32.0 works only up to PG 18.6; 18.7 needs 2.32.1).
- Dated liability to re-evaluate PG 19 when BOTH hold: Timescale declares PG 19 support, and a
  19.x minor (>= 19.1) exists.
- Rejected: PG 19 without Timescale as the default and 18 only when Timescale is needed — it
  doubles the combinations to test and monitor.

### Opus validation of the skill-weight gate — round 1: CHANGES REQUIRED (2026-11-27)

Worktree `.wt/weight`, uncommitted. All nine numbers matched an independent hand count; 19 of 23
mutations RED. Blocker: partial blindness is silent — rewording a SKILL.md opening paragraph
(semicolon-joined conditional, unbackticked reference, sentence moved to the next paragraph)
halves the measured set with exit 0, because a shrink never fails. Under-measurement: later-step
unconditional reads are invisible (prod-bootstrap really loads ~256 KB, not 80 KB).
Decision for round 2: measure TWO sets — EAGER (opening paragraph, hardened) and REACHABLE (every
`references/` mention anywhere, no prose parsing, an upper bound) — and ratchet the FILE LIST of
each in both directions, so any change in what a skill loads is a reviewed diff of the baseline.
REACHABLE ceiling 128 KB. Fresh Sonnet implementer dispatched.

### OpenRouter — researched, NOT being built (user decision 2026-11-27)

Notes in `notes/openrouter-integration.md`. Findings: Claude Code works through it only for Claude
models (Anthropic does not support routing Claude Code to non-Claude models through any gateway);
Codex is documented to work but needs the stateless Responses endpoint, untested on 0.172; per-key
spend limits are real. The user asked how it could be added, read the options, and said to leave
it as is. Do not schedule any OpenRouter work unless asked again.

### Open / blocked

- Unknown from the Codex binary, to resolve from official docs in Phase 4: agent-role TOML schema,
  `skills.config` keys, hook stdin JSON contract.
- Not yet verified: whether `skill-optimizer run` works with the current Codex auth.
- Pending user decision (asked 2026-11-27): the user said "push all this to main". Not done: this
  session may not push to master or merge, and no code branch has an Opus OK yet. Options offered:
  PRs to master per branch as each is approved (default, in progress); a PR of `goal/state`; or
  draft PRs of unvalidated code. Also found today: `probe-wiring.sh` has a load-dependent false
  FAIL (`grep -q` under pipefail) — fix in progress on branch `fix/grepq-under-pipefail`.

### Queue (next iterations)

1. Phase 0: corpora for prod-implement, prod-spec, prod-new, prod-bootstrap, prod-test-synth,
   prod-incident, prod-ops, prod-curate. Retire the stale skill-optimizer presentation in README.
2. Phase 3 quick win: prod-new read-first set 258 KB → bounded pulls; SKILL.md body + read-first
   size gate; wire token-report.
3. Phase 4: `_shared/hosts.md`, dual installer, host-vocabulary probe, per-host smoke.
4. Phase 1: greenfield concept in prod-spec, monorepo + React + DS + Playwright template, dim 28.
5. Phase 5: Go + Rust + Python (see above) — corpus first, then verify-standard adapters, then templates.
   Phase 6: PostgreSQL 18 + TimescaleDB, born monitored (see above) — after the research notes land.
6. Phase 2: papers loop.
7. `make check-fast` runtime: `gate-hygiene-fitness.sh` is superlinear in file length (70 lines 4 s, 130 lines 14 s, 190 lines 79 s, measured 2026-11-27); 100 s idle, 30+ min under load.
