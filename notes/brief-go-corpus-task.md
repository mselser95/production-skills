# Brief: author ONE Go task for the prod-review eval corpus

Repo worktree: /Users/matiasselser/dev/personal/production-skills/.wt/eval-corpus-go-more
(branch `eval/corpus-go-more`). Create ONLY the one directory you were assigned under
`benchmarks/eval/corpus/prod-review/`. Other agents are creating sibling directories in the
same worktree right now: never touch any directory but yours, never touch `_lib/` or an
existing task. Do NOT commit or push, do NOT run any model. English only. Never read a path
containing "terrace".

## Machine rules (shared laptop, saturated twice today by heavy checks)
Do NOT run `make check-fast`, `make selftests`, `make evidence`, `make eval`,
`scripts/mutation-baseline.sh`, or `benchmarks/eval/lint.sh` (the orchestrator runs lint once
for everyone). Allowed: `go build/vet/test` on your tiny module in a scratch dir, your task's
own `grade.sh`. One process at a time, nothing in the background, no command over 60 s. Never
touch Docker containers or processes you did not start. Use a scratch dir whose name includes
your task id; delete it at the end; `pgrep` shows nothing of yours.

## Purpose
The corpus measures whether the `prod-review` skill makes an agent review code better than the
same agent without it. A task is a tiny Go module with an UNCOMMITTED change. `seeded` tasks
hide ONE real defect at a known line range; `clean` tasks have none (any `defect`-class finding
is a false positive).

## Conventions — read fully, copy exactly
`benchmarks/eval/corpus/prod-review/_lib/README.md` (pass rules, modification rule,
context-artifact normalisation, adding a task, regenerating `expected.diffhash`),
`_lib/output.schema.json`, `_lib/regen_expected.sh`, and two existing tasks completely:
`seeded-08-batch-writer/` and `clean-04-job-runner/` (task.json, fixture/ incl. production.yaml
and `.prod/context/*.yaml`, fixture.setup.sh, grade.sh, reference/solve.sh, README.md,
expected.diffhash). Also `prod-review/SKILL.md` lines 1-80 and `prod-spec/SKILL.md` lines
100-145. Use the IDENTICAL `prompt` string (byte-for-byte), `"agent_mode":"read-only"`,
`"kind"`, and add `"language": "go"`. Same grade.sh / solve.sh / README shapes.

## The fixture
A tiny Go module, stdlib only, `go 1.22`, 2-5 source files, 60-200 lines, at least one passing
`_test.go`, realistic service-style code, in the DOMAIN you were assigned. Context artifacts in
the base commit, following the normalisation rule in `_lib/README.md` (events declared from what
the change actually does; consistent with prod-spec; same shape for seeded and clean). The
change is 15-40 changed non-test lines with 3-6 comment lines, applied by `fixture.setup.sh`.
Nothing in the fixture, patch, names, comments or tests may hint at a defect.

### If your task is SEEDED
One defect of the CLASS you were assigned: real and reviewer-worthy, not reported by the
compiler or `go vet`; after `fixture.setup.sh`, `go build ./... && go vet ./... && go test ./...`
pass (the existing tests do not catch it); you DEMONSTRATE it with a scratch test outside the
repo (fails, leaks, deadlocks within a timeout, or races under `-race`) and record the failing
line; it lives in one contiguous range of at most 6 lines in one file.

### If your task is CLEAN
A genuinely correct change with the "suspicious but right" TRAIT you were assigned. This corpus
has shipped a "clean" task containing a real defect THREE times. Write scratch property and
behaviour tests that try hard to break your change — boundaries, zero / negative / max values,
overflow, cancellation, `-race` with many goroutines, goroutine counts before and after — and
report what you tried. If they find a bug in your draft, fix the draft and say so. Follow your
assignment on whether the change ADDS a new file or only modifies existing ones.

## Verify (scratch dir: copy fixture, `git init` + commit with a local identity, run setup)
build / vet / test pass and `gofmt -l` is empty on the base and post-change trees; empty output
→ grade exit 1; reference/solve.sh → exit 0; seeded: a wrong-line defect finding → 1; clean: one
`defect`-class finding on a source file → 1; edit a tracked file → 1 with
`"modified_files":true`; missing workdir → 2. `expected.diffhash` via
`_lib/regen_expected.sh <your-task-dir>`. `shellcheck -S warning` on your three scripts.

## Hand-back (<= 15 lines)
AUTHORED or BAIL; id, split, kind, domain; seeded: class, file:lines, the demo's failing line /
clean: the trait, adds-a-file yes/no, break attempts and whether they found a bug in a draft;
the check results; events declared; cleanliness; NOT VALIDATED.
