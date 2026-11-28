# Skill evaluation harness

Question: **does a skill make the agent produce better output than the same agent without
it?** Each task (x arm x host x rep, one `run.sh` call = one JSONL row) is graded by a script the agent never sees.

## Method
| | |
|---|---|
| Arms | `skill`: the skill dir is installed in the host's skill location and ONE line is appended to the prompt (`Use the <skill> skill for this.`). `bare`: nothing installed, prompt unchanged. |
| Hosts | `claude` (Claude Code, `claude -p`), `codex` (`codex exec --json`). `stub` is a fake host for the selftest only. |
| Grading | `grade.sh <workdir> <agent-output-file>`: exit 0 pass / 1 fail / 2 grader error, one JSON metrics line on stdout. |

**Isolation.** Every cell gets a fresh workdir (fixture, `git init`, one commit, optional `fixture.setup.sh`) and a throwaway host home (`CLAUDE_CONFIG_DIR` / `CODEX_HOME`): the user's real `~/.claude*` / `~/.codex` would contaminate BOTH arms. `lib/runenv.py` is the one **environment allowlist**: `PATH LANG LC_ALL TERM`, `HOME` = the isolated home, the config-dir var, per-cell `GOCACHE` and `TMPDIR`, `GOTOOLCHAIN=local`, `GOPROXY=off`, and the single auth variable passed BY NAME (never in argv). No `CLAUDECODE`, session ids or `OLDPWD`. Skills are copied with `cp -RL` (`references/` are symlinks into `_shared/`).

**Auth order** (never printed; credential lines run with xtrace off). Claude: exported
`CLAUDE_CODE_OAUTH_TOKEN`, else `ANTHROPIC_API_KEY`, else the ACCESS token (never the refresh
token) from the real config dir's `.credentials.json` / the macOS keychain via `security`.
Codex: exported `CODEX_API_KEY` (no file at all), else the real `auth.json` is copied into the isolated home. No credential: exit 78, row `error:"auth"`.

**Credential contract (Codex), nothing leaves the cell.** (1) The copy is made once, before the CLI starts, with
`O_NOFOLLOW` (a symlinked or non-regular real `auth.json` is refused, exit 78), into a NEW file, mode 0600. (2) It is **never
written back**, with or without the sandbox. (3) It is scrubbed after the CLI exits and on the exit paths listed under **Scrub** below (NOT "every exit path": SIGKILL is not one).
**Write-back history:** the adapter used to write a changed copy back to the real file so a refresh token rotated mid-cell was not lost. The
agent owns the cell home, so it chose the bytes of the user's real login: `echo '{"tokens":"X"}' >$HOME/auth.json`, or `ln -s ~/.ssh/id $HOME/auth.json`
(the adapter followed the link, the next cell read the key). Closed by deleting the write-back (selftest 14n, 14v, 14v2, 14v4).
**Consequence:** if Codex rotates its refresh token during a cell the real file may be left stale and you may have to log in again; avoid it with
`CODEX_API_KEY`. Opt-in `EVAL_CODEX_AUTH_READONLY=1` (sandboxed only) makes the staged copy unwritable, so Codex cannot rotate inside a cell (14v3 proves
no write, mv-over, ln -sf, rm, link or chmod works); whether Codex STARTS with a read-only auth file is NOT VALIDATED (needs one paid run), hence off by default.
**Results.** The answer and the usage are parsed from the stdout/stderr the ADAPTER captured into its own `sbx.*` dir (never re-allowed), not from any file in the
cell home (the old `.eval-codex.jsonl`, `-last.txt`, `.eval-claude.json` could be forged by rename-over; selftest 19x, 19x2). Codex's `-o` is no longer passed.
**Scrub (the agent writes the cell home, so it can make the copy undeletable).** The agent may `chmod 000` / `500` a directory, `chflags uchg` a file (settable
under the profile: probed), or `ln` the credential to another name in its tmp/gocache. Sequence, in order: (1) **permission reset** from outside (`lib/scrub.py reset`: owner-rwx
on every directory, immutable flags cleared, symlinks never followed); (2) **fd wipe**: at staging, `lib/scrub.py hold` keeps an open descriptor on the staged INODE in a small
background process (pid in `sbx.*/holder.pid`); closing the adapter's end of its FIFO (or SIGTERM/HUP/INT, or the adapter dying) makes it overwrite with zeros, `ftruncate(0)` and
`fsync` through that descriptor, which destroys the bytes for EVERY hard link whatever its name or directory mode (a write through an open fd works even with `uchg`: probed);
(3) **unlink** the name; (4) **cell removal** by `run.sh` (reset, `rm -rf`, one retry) of `home gocache celltmp work sbx.*` BEFORE the row is written; (5) **verification**:
the path must not exist; (6) **error path**: anything that remains gives row `error:"scrub-failed: <path>"`, `run.sh` exit 4 (a live loop STOPS), and a loud `SCRUB FAILED` stderr
line naming the directory that may still hold a credential copy; the adapter exits 80 and prints the same. An agent's own `cp` of the credential is a different inode: it lives
until the cell removal (which the reset makes reliable) and is the one reason for steps 4-6. Scrubbing runs on normal exit, a failing CLI, a timeout (limited.py kills the group,
the holder wipes on SIGTERM), TERM/INT/HUP of the adapter or `run.sh`, and `EVAL_KEEP=1` (dirs kept, credential never). **A SIGKILL of both adapter and `run.sh` is NOT covered
by the trap**: the holder sees EOF on its FIFO and wipes the content when the adapter dies (so the file is empty), but a 0600 file and the cell dir remain until the next harness
start: every `run.sh` start runs a **startup sweep**: `eval-cell.*` dirs it owns (same uid, real directory, never a symlink, name prefix only) under its temp root older than
`EVAL_SWEEP_MINUTES` (default 180, minimum 30), without a `.eval-keep` marker, are removed with the same reset-then-remove and listed on stderr; anything else is never touched
(selftest 21h). Claude: nothing secret is written into the cell (the token is in the environment only, passed by name); `run.sh` still removes a `.credentials.json` there.
Whether the Claude CLI persists a token into its config dir on its own is NOT VALIDATED without a model run.
**Grader.** It runs OUTSIDE the sandbox, so it only ever reads a workdir the agent could not write. One predicate, `grade_ok` in `run.sh`, used BEFORE the host starts (no model call
is spent on a cell that cannot be graded; `lib/live.sh` asks `run.sh --preflight` and skips such cells with a reason) and again after it:

| sandbox of the cell | `agent_mode` | graded? |
|---|---|---|
| `seatbelt` | `read-only` | yes (the profile denies every write to the workdir), subject to the tamper check |
| `n/a` (the stub host, no agent) | `read-only` | yes, subject to the tamper check |
| `seatbelt`, `n/a` | `workspace-write` | no: `grader-unconfined`, host never started |
| `off` (`EVAL_CLAUDE_NO_SANDBOX`/`EVAL_NO_SANDBOX`) or `codex` (`EVAL_NO_SANDBOX` on Codex: its `-s workspace-write` makes the workdir writable in EVERY mode) | any | no: `grader-unconfined`, host never started |

Tamper check: the digest of the workdir's git metadata (everything under `.git` except objects/index/logs/refs/packed-refs, plus every `.gitattributes` and `.gitmodules`) is taken after the workdir
is prepared and BEFORE the CLI starts and compared after it; a difference gives `workdir-tampered`, no grading. The grader's git runs neutralised (`GIT_CONFIG_NOSYSTEM`, `GIT_CONFIG_GLOBAL=/dev/null`,
env-injected `core.fsmonitor=false`, `core.hooksPath=/dev/null`, `core.sshCommand`, `core.pager`, `core.editor`, `core.attributesFile`, `credential.helper`, `protocol.ext.allow=never`, `GIT_EXTERNAL_DIFF`): that list can
not be complete (`diff.external`, `filter.*`, aliases, `include.path` ... live in the repo-local config), so the digest is the control and the env is defence in depth. `EVAL_SKIP_GRADER=1` runs
the host without grading (tests of the host wiring; row `grader-skipped`); `live.sh` refuses it. **NOT done:** the grader is not itself run under a read-only seatbelt profile (next task).
The only git runs inside a cell after the CLI starts are the grader's (`ls-files -s`, `status`); the harness's own (`workdir.sh` init/commit, `fixture.setup.sh`, `--exec-path`, `git log` of the harness repo) run before the CLI or outside the cell.
**Stream integrity (Codex).** `lib/parse_codex.py` accepts exactly one terminal `turn.completed` and nothing after it, and one final agent message after the last tool call; otherwise exit 3, row `error:"stream-trailing-data"`,
no answer, no usage. RESIDUAL: a tool shares the CLI's stdout, so it can write well-formed events BEFORE the terminal event and the harness cannot tell them from the CLI's own; usage numbers are therefore "as reported by the CLI process tree".
**Processes outliving the cell.** The CLI's stdout is read by `lib/limited.py --capture` (outside the cell); after the CLI's process group is killed the pipe gets ONE 2 s grace and is closed;
if it was still held, row `error:"orphan-process"` (adapter exit 81). Not fixable here: seatbelt has no operation that denies `setsid`, and the CLI must fork, so a determined agent can leave a sandboxed,
network-capable process running until it exits or the user logs out; one that does not hold the stdout pipe is undetectable (no pid is known).

**Confinement (`agent_mode`).** On macOS BOTH hosts run under ONE seatbelt profile (`sandbox-exec -f`,
generated per cell by `lib/seatbelt.py`, same `agent_mode` semantics), so their rows are comparable
(`sandbox:"seatbelt"`). Codex's own sandbox is switched off there (`-s danger-full-access`, it cannot
nest a seatbelt in ours; `-c approval_policy=never`): `danger-full-access` is in its argv ONLY with the
outer wrapper. Its real binary lives in the real Codex home beside `auth.json`: only its `bin/` dir is
re-allowed (`--reallow-read`, after the denies; trial-found), the rest of that home stays denied. **Writes** are denied except in the isolated home, GOCACHE, a per-cell
TMPDIR and, only in `workspace-write`, the workdir. **User data is default-deny for reads too**:
read and write of `/Users /Volumes /tmp /var/folders /var/run` and of any `*docker.sock` are denied,
plus unix-socket connects under those roots and to docker/agent sockets (trial-found, keep: a file
deny does NOT block `connect()` on a unix socket, and a `remote unix-socket` rule takes ONE filter,
several silently stop blocking: one rule per path), then re-allowed by real path: home, GOCACHE,
TMPDIR (read+write), the workdir (read; write only in `workspace-write`), the install root of the
`claude` binary (the dir of its real file: the versions dir of the CLI under the user's home; for
`codex`, its `bin/` dir) and
the Go toolchain / git exec path only if a denied root hides them. The repo (`.git`, `corpus/`,
`results/`) and the real config/auth dirs are denied again afterwards; the task dir is only kept
from re-allows (never named). The profile sits in its own `sbx.XXXXXX` dir beside the cell home
(never re-allowed) and names no task. `stat` (metadata only, literals, no listing) is allowed on the ancestors of the cell (`/private/var/folders[/<xx>[/<yyyy>[/T[/eval-cell.X]]]]` and the `/var` form, or `/tmp`, `/private/tmp`) and, for Codex's re-allowed `bin/`, on `/Users`, `~`, `~/.codex`, `~/.codex/packages`, `.../standalone`, `.../releases`, `.../releases/<ver>` (CLIs canonicalise their home). **Existence oracle:** `stat` of a denied path that exists answers EPERM, of a missing one ENOENT, so names under those dirs can be enumerated by guessing; contents and listings stay denied. A re-allow covering something denied fails closed
(`error:"sandbox"`). Sandbox ON: `Read Glob Grep Bash` unrestricted (`dontAsk`; `workspace-write`
adds Edit/Write), no pattern list. Sandbox OFF (opt-out): only a narrow allowlist (`go
version|build|vet|test`, `git status|diff|log|show`) plus escape-flag deny patterns (`go test
-exec`, `git -c`...) confines it. No `sandbox-exec`, a non-macOS host, or a profile that will not
run fails the cell (`error:"sandbox"`, exit 3), never a silent unconfined run. **Live runs are
macOS-only unless you opt out with `EVAL_NO_SANDBOX=1` (host-neutral; `EVAL_CLAUDE_NO_SANDBOX=1` is a Claude
alias). Claude: loud warning, row `sandbox:"off"`, unconfined. Codex: runs under its OWN `-s workspace-write`
(writes confined; **reads unconfined**: answer key and user files readable), warning, row `sandbox:"codex"`. Rows carry `sandbox: seatbelt|codex|off|n/a`; reports never pool different values.
**Threat model.** With unrestricted Bash and an open network, anything the agent can READ it can
send out. Readable by design: the workdir, the cell's home/GOCACHE/TMPDIR, the CLI's install dir
(its versions dir) and system dirs (`/usr /opt /Library /etc`); a secret there, or outside the
denied roots (a share not under `/Volumes`), is exposed. **TCP is NOT blocked for either host**
(seatbelt cannot filter by host; Claude's WebFetch/WebSearch are denied) and the model's own credential
is in the cell (Claude: the process environment; Codex: its `auth.json` copy in the isolated home, or
`CODEX_API_KEY`), so a hostile fixture could exfiltrate it. **Known noise:** `/bin/bash` 3.2 here-docs ignore `TMPDIR` and write `/tmp` (denied; `TMPDIR` itself is exported, selftest 15z4), and `xcrun` shims print cache errors; no write rule outside the cell is added for either.

**Structured output.** If `corpus/<skill>/_lib/output.schema.json` exists, `run.sh` passes it as the adapter's 9th argument (empty = none; the stub ignores it) and the agent must answer with ONE JSON document. claude: `--json-schema <schema as one line of JSON>` (`--help` shows it inline; it does NOT name the result field, so `lib/parse_claude.py` takes `structured_output` if an object, else `result`). codex: `--output-schema <file>` (the answer is the last JSONL `agent_message` of the captured stdout; stream shape NOT VALIDATED without a model run); its prompt is `-` with stdin redirected from the prompt file, so a caller's open pipe cannot hang it. No schema file: no flag. Rows carry `kind` and `language` (from `task.json`) and `output_valid`: `null` without a schema, else `true` iff the output file parses as a JSON OBJECT. Prose or nothing still yields a row (`output_valid:false`; the grader runs and fails it).

**Hidden graders.** `grade.sh`, `reference/`, `task.json` live beside `fixture/`, never enter the workdir; the grader runs after the agent with cwd outside. **Failures still count.** A host that will not start, a timeout (process group killed), a crash, an auth failure or a grader exit 2 each produce a row with `pass:false` and an `error`. `pass` = grader exit 0 AND host exit 0 AND no timeout. TERM/INT on `run.sh` kills the host process group and removes the temp dirs. **Held-out rule.** `heldout` tasks never tune a skill, and every skill with tasks keeps at least one (lint enforces it). Reports never pool splits, models, sandbox modes, kinds or languages.

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
