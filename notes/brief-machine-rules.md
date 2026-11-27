# Machine and conduct rules for every implementer (shared laptop)

This repo's heavy checks saturated the owner's laptop twice on 2026-11-27. Therefore:

- Do NOT run on the host: `make check-fast`, `make selftests`, `make evidence`, `make gates`,
  `make eval`, `scripts/mutation-baseline.sh`, `_shared/probes/shard-selftest.sh`,
  `_shared/probes/verify-standard.sh`.
- Run only your own tests and cheap single commands. ONE process tree at a time. Nothing left
  in the background when you hand back. No "wait until X finishes, then run Y" loops. No
  single command over 90 seconds; if a build is slower, say so and stop.
- Docker: you may start containers ONLY when your task says so, each with
  `--cpus 1 --memory 1g` and a name starting with the prefix your task gives you, and you must
  remove exactly those by name. NEVER stop, kill, remove or prune any container, image, volume
  or network you did not create; never `docker system prune`; never `docker ps -q | xargs …`.
  Record `docker ps -a --format '{{.Names}} {{.State}}'` before and after and report any
  difference.
- Never kill a process you did not start, and never with a broad pattern (`pkill node`).
- Use absolute paths. Never `cd` into a path built from a glob: an agent ran `go test` inside
  the wrong repository that way.
- Work ONLY inside the worktree and directories your task names. Never read or reference any
  path containing "terrace". Never read the real `~/.claude*`, `~/.codex`, `~/.ssh`.
- Do NOT commit or push. Leave build outputs out of the tree: add a `.gitignore` for
  `target/`, `node_modules/`, `dist/`, `__pycache__/`, `.venv/`, coverage, caches — and delete
  them before handing back.
- English for all file content. No company, product or person names anywhere.
- Every check you add must be proven by mutation: break the guarded thing, show the RED line,
  revert. Every check must be cheap by construction: no per-line or per-case process forks;
  target under 15 seconds for a package's whole test run.
- If the task is ambiguous or a fact in it turns out wrong, STOP and report instead of
  inventing. If it is really several tasks, BAIL with a proposed split.
- Hand-back: IMPLEMENTED or BAIL on line 1; what you built (files, counts); test counts and
  wall times; mutations with their RED lines; `git status --porcelain` summary; proof nothing
  of yours is running and no temp dir is left; a NOT VALIDATED section.

## A blocked command stays blocked
If the permission system or a safety check refuses a command (an `rm -rf`, a `make` target,
a Docker call), do NOT reach the same effect another way (Python `shutil.rmtree`, `find
-delete`, a wrapper script). Stop that step, leave the files where they are, and report the
exact command and the refusal in the hand-back. Leftover scratch directories are fine: name
them so the orchestrator can remove them.

## Scoped inner check only (adopted 2026-11-27, from the swarm-orchestration study)
Measured on this goal's own session: agents spent 41.5% of their time in gate-like Bash
(about 5.8 heavy gate runs per implementer task, plus poll-wait loops), and THAT is what
saturated the host. So, inside an agent:
- Run only the check your change needs: your own test or selftest file, plus the single gate
  whose inputs your diff touches. Budget: 15 seconds per run. Count your runs and report them.
- Never the full suite (`make check-fast`, `make selftests`, `make evidence`,
  `scripts/mutation-baseline.sh`, `verify-standard.sh`): the orchestrator runs it ONCE per
  batch on the joined tree, in a container.
- Never a poll-wait loop (`while …; do sleep …; done`, `until …`). If something is not ready,
  stop and report.
- A validator does not re-run the suite either: it proves non-vacuity by mutating only the
  check the change adds, on a scratch copy.
