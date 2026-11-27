# Skill evaluation harness

Question: **does a skill make the agent produce better output than the same agent without
it?** Each task (x arm x host x rep, one `run.sh` call = one JSONL row) is graded by a script the agent never sees.

## Method
| | |
|---|---|
| Arms | `skill`: the skill dir is installed in the host's skill location and ONE line is appended to the prompt (`Use the <skill> skill for this.`). `bare`: nothing installed, prompt unchanged. |
| Hosts | `claude` (Claude Code, `claude -p`), `codex` (`codex exec --json`). `stub` is a fake host for the selftest only. |
| Grading | `grade.sh <workdir> <agent-output-file>`: exit 0 pass / 1 fail / 2 grader error, one JSON metrics line on stdout. |

**Isolation.** Every cell gets a fresh workdir (fixture, `git init`, one commit, optional
`fixture.setup.sh`) and a throwaway host home (`CLAUDE_CONFIG_DIR` / `CODEX_HOME`): the user's
real `~/.claude*` / `~/.codex` would contaminate BOTH arms. `lib/runenv.py` is the one
**environment allowlist**: `PATH LANG LC_ALL TERM`, `HOME` = the isolated home, the config-dir
var, per-cell `GOCACHE` and `TMPDIR`, `GOTOOLCHAIN=local`, `GOPROXY=off`, and the single auth
variable passed BY NAME (never in argv). No `CLAUDECODE`, session ids or `OLDPWD`. Skills are
copied with `cp -RL` (`references/` are symlinks into `_shared/`).

**Auth order** (never printed; credential lines run with xtrace off). Claude: exported
`CLAUDE_CODE_OAUTH_TOKEN`, else `ANTHROPIC_API_KEY`, else the ACCESS token (never the refresh
token) from the real config dir's `.credentials.json` / the macOS keychain via `security`.
Codex: exported `CODEX_API_KEY`, else `auth.json` copied (600) into the isolated home; a
rotated copy is written back (compare-then-rename, only if the real file is unchanged since
the copy) and the copy is deleted on every exit path. Limits: a TOCTOU window; a token
rotated right before a SIGKILL is lost; a concurrent interactive `codex` can invalidate the
refresh token, so use `CODEX_API_KEY` unattended. No credential: exit 78, row `error:"auth"`.

**Confinement (`agent_mode`).** Codex: `-s workspace-write`, an OS sandbox (writes only in
the workdir plus the per-cell GOCACHE `--add-dir`); its default blocks outbound network
(from Codex's documented defaults, NOT verified here). Claude: macOS seatbelt
(`sandbox-exec`, profile per cell from `lib/seatbelt.py`) denies every file write except the
isolated home, GOCACHE, a per-cell TMPDIR and, only in `workspace-write`, the workdir.
The profile also DENIES READS of `~/.ssh .aws .gnupg .config/gh .docker .kube .netrc`, the real
`~/.claude*` / `~/.codex`, `~/Library/Keychains`, `<repo>/benchmarks/eval/corpus` and the task
dir (the answer key). Sandbox ON: `Read Glob Grep Bash` unrestricted (`dontAsk`; `workspace-write`
adds Edit/Write with `acceptEdits`), no pattern list. Sandbox OFF (opt-out): the narrow
allowlist (`go version|build|vet|test`, `git status|diff|log|show`; `gofmt` in
`workspace-write`) plus deny patterns for `go test -exec`, `go build -o`, `git -c` etc. are
the only confinement (wildcard-before-flag matching is unconfirmed).
No `sandbox-exec`, a non-macOS host, or a profile that will not run fails the cell
(`error:"sandbox"`, exit 3), never a silent unconfined run. **Live Claude runs are macOS-only
unless you opt out with `EVAL_CLAUDE_NO_SANDBOX=1`** (loud warning, row `sandbox:"off"`);
a Linux confinement is future work. Rows carry
`sandbox: seatbelt|codex|off|n/a`; reports never pool different values. **Claude's network
is NOT blocked** (seatbelt cannot filter by host; only WebFetch/WebSearch are denied) and the
agent holds its own API credential. Threat model: with unrestricted Bash and an open network,
anything the agent can READ it can send out, so the read-deny list is the control (a path
missing from it is exposed). Fixtures are authored and reviewed here, so the residual risk is
a model following injected text in a fixture; a hostile fixture could exfiltrate the session
credential on the Claude side.

**Structured output.** If `corpus/<skill>/_lib/output.schema.json` exists, `run.sh` passes it as the
adapter's 9th argument (empty = none; the stub ignores it) and the agent must answer with ONE JSON
document. claude: `--json-schema <schema as one line of JSON>` (`--help` shows it inline; it does
NOT name the result field, so `lib/parse_claude.py` takes `structured_output` if an object, else
`result`). codex: `--output-schema <file>` + `-o <home>/.eval-codex-last.txt` (JSONL `agent_message`
is the fallback); its prompt is `-` with stdin redirected from the prompt file, so a caller's open
pipe cannot hang it. No schema file: no flag. Rows carry `kind` and `language` (from `task.json`) and `output_valid`:
`null` without a schema, else `true` iff the output file parses as a JSON OBJECT. Prose or nothing
still yields a row (`output_valid:false`; the grader runs and fails it).

**Hidden graders.** `grade.sh`, `reference/`, `task.json` live beside `fixture/`, never enter
the workdir; the grader runs after the agent with cwd outside. **Failures still count.** A host
that will not start, a timeout (process group killed), a crash, an auth failure or a grader exit 2
each produce a row with `pass:false` and an `error`. `pass` = grader exit 0 AND host exit 0 AND no
timeout. TERM/INT on `run.sh` kills the host process group and removes the temp dirs.
**Held-out rule.** `heldout` tasks never tune a skill, and every skill with tasks keeps at least
one (lint enforces it). Reports never pool splits, models, sandbox modes, kinds or languages.

## Reading the report
`python3 benchmarks/eval/report.py results.jsonl [--markdown]`
- per (skill, host, model, sandbox, split, **language**, **kind**, arm): n, success rate with a Wilson 95% interval
  labelled **rep-level (optimistic)** (reps of one task are not independent), pass^k (share
  of tasks whose k reps ALL passed; k printed; unequal reps across arms print a WARNING),
  the mean per row of `false_positives` and `found` (descriptive), and tokens / seconds **spent per
  resolved task** = total over ALL rows (failed attempts included) / passing rows, `n/a` if none;
  rows with no usage are excluded from the token figure and counted ("N no usage"), never 0.
- the **verdict** comes from a task-clustered paired estimate: per task the pass rate with
  the skill minus without it, over tasks present in both arms (unpaired ones are listed);
  effect = mean over tasks, 95% interval = two-level percentile bootstrap (resample TASKS,
  then reps inside each task per arm; 10,000 resamples, fixed seed). `helps`: interval
  entirely above 0; `hurts`: entirely below; `no evidence`: it straddles 0 (usually "not enough
  data", NOT "no effect"). Under 5 paired tasks: `insufficient tasks (n=k)`.
- **Kinds are never pooled**: all of the above is per `kind`, with no verdict across kinds, so more
  real finds cannot be netted against more false alarms. For kinds `seeded` and `clean` two named
  lines per (skill, host, model, sandbox, split, language): `recall (seeded)` = paired skill-minus-bare pass
  rate on seeded tasks; `false-positive control (clean)` = the same on clean tasks (passing = no
  false defect raised, so `helps` still means better). `helps` + `hurts` = finds more, cries wolf more.
  Each has an interval and verdict; `insufficient tasks (n=k)` under 5 paired tasks of THAT kind and language.
- **Languages are never pooled either** (`task.json` `"language": "go|rust|python"`, required): every
  block and both named verdicts are per language. The 5-paired-task floor therefore applies per
  (kind, language, split). Today's corpus (prod-review) has, per split (dev and heldout alike):
  Go 4 seeded + 2 clean, Rust 2 seeded + 1 clean, Python 2 seeded + 1 clean. No (kind, language,
  split) reaches 5, so every verdict this corpus can give today is `insufficient tasks (n=k)`; a
  `helps`/`hurts` needs at least 5 paired tasks in that cell (Go seeded needs 1 more per split,
  Go clean 3 more, Rust/Python seeded 3 more, Rust/Python clean 4 more).
- an unparseable line, or a row without `kind` or `language` (old file), is an error (file:line, exit 1).
## Adding a task
`corpus/<skill>/<task-id>/` (`<skill>` is one of the nine skill dirs, `<task-id>` = `id`):
```
task.json            {"id","skill","split":"dev|heldout","kind":"<opaque, required>","language":"<non-empty, required>","prompt",
                      "timeout_s","max_budget_usd","agent_mode":"read-only|workspace-write"}
fixture/             what the agent sees
fixture.setup.sh     optional, beside fixture/; runs in the workdir before the agent
grade.sh             <workdir> <agent-output-file> -> exit 0/1/2 + one JSON line
reference/solve.sh   <workdir> <agent-output-file> -> a state the grader must accept (a JSON object if schema)
```
The prompt is host-neutral and must not name the skill. JSON only. Every python call is
`python3 -I -B` and the scripts export `PYTHONDONTWRITEBYTECODE`; the selftest fails on any
`__pycache__` under `benchmarks/eval/` outside `corpus/`. A `corpus/_*` dir (e.g. `_lib`) is shared
helper code: lint skips it; each executable `corpus/*/_lib/*-selftest.sh` runs under `make eval`.
Lint needs `kind` and `language`, shows each grader RED on the unsolved fixture and GREEN on the reference.

## Running
```
make eval            # hermetic, free: selftest + corpus helper selftests + lint (CI: job `gates`)
EVAL_LIVE=1 make eval-live N=3              # PAID: corpus x claude,codex x skill,bare x 3
bash benchmarks/eval/run.sh --task benchmarks/eval/corpus/<skill>/<id> \
     --arm skill --host claude --rep 1 --out /tmp/r.jsonl [--model haiku]
```
`eval-live` refuses unless `EVAL_LIVE=1`, prints the plan and arm-order seed, preflights
credentials, and writes `results/<UTC date>T<HHMMSS>Z-<harness_sha>.jsonl` (one file per run)
plus the markdown report. Arm order is shuffled per (task, host, rep) from the seed
(`order_seed` in every row). A cell that cannot run here (auth or sandbox) stops the loop.
Pin models with `EVAL_MODEL_CLAUDE` / `EVAL_MODEL_CODEX`; `EVAL_KEEP=1` keeps a cell's dirs
(never its credentials). Not in CI; hermetic `make eval` runs in `pr.yaml` `gates` (cases needing
seatbelt/keychain print `SKIP <id> (darwin-only)`, never counted as passed). `skill_sha` /
`harness_sha`: `<sha>` clean, `<sha>+dirty` if it differs from HEAD, `unknown` if never committed.
Linux check: `docker run --rm -v <repo>:/src:ro golang:1.27-bookworm bash -c 'cp -r /src /w && cd /w && bash benchmarks/eval/selftest.sh'`.

## NOT measured
- Anything the grader does not check (style, explanation quality, breakage outside graded files).
- **Codex has no spend cap:** `max_budget_usd` binds Claude only; `timeout_s` is its only bound.
- Host CLI versions and model snapshots (drift; pin one model per host or arms are not
  comparable); built-in host instructions load in both arms. Neither host is a hard boundary.
