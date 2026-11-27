# prod-review corpus: shared grader

The agent returns its review as ONE JSON document that conforms to
`output.schema.json` (the harness hands the schema to the host: `claude -p
--json-schema`, `codex exec --output-schema`). `grade_findings.py` only compares
that data; it never reads prose, headings, labels or vocabulary. Each task's
`grade.sh` calls it with the defect file and line range (or `--clean`). Exit 0
pass, 1 fail, 2 grader error (missing workdir, output file or `expected.diffhash`).
It prints exactly one JSON line:
`found, missed, false_positives, non_defect_findings, nonspecific_findings, context_findings,
unknown_file_findings, modified_files, parse_error, schema_error, kind`.

## The document
```
{ "verdict": "defects_found" | "no_defects",
  "findings": [ { "file": "<path from the repo root>", "line_start": N, "line_end": N,
                  "class": "defect" | "missing_test" | "not_validated" | "note",
                  "severity": "blocker" | "warning" | "nit", "summary": "<one sentence>" } ] }
```
`class` is the reviewer's own statement of what the item IS:
- `defect`: this change is wrong and should not merge as it is.
- `missing_test`: behaviour with no test. `not_validated`: something the reviewer could not check.
  `note`: any other remark, question or praise. These three are explicitly NOT defects.

`severity` is ignored by the grader. The `prod-review` skill uses WARNING for a smell and a bare
reviewer may use "warning" for a bug, so the word does not say whether the item is a defect;
`class` does. A `nit`-severity `defect` on the right line is found; a `blocker`-severity `note` is not a defect.

Parsing: whitespace and ONE surrounding ```` ```json ```` fence are tolerated; anything else that
is not JSON (empty, `LGTM`, prose before the JSON, truncated, invalid UTF-8) is `parse_error: true`.
Validation is strict: exact keys at both levels, enum values, integers (not strings, floats or
booleans), `line_start >= 1`, `line_end >= line_start`. An invalid document is `schema_error: true`.
`verdict` must agree with the findings: `no_defects` together with a `defect`-class finding, or
`defects_found` without one, is a schema error (judged on every finding, whatever its file).
Both errors fail the task with exit 1, never 2 and never a traceback.

## Pass rules
Each finding's `file` is normalised (leading `./` stripped, an absolute path under the workdir made
relative). A `file` that is not a regular file inside the workdir is counted in
`unknown_file_findings` and otherwise ignored. A `file` under `.prod/` or equal to `production.yaml`
is a context finding: counted in `context_findings`, ignored for both kinds.
A finding is SPECIFIC when `line_end - line_start + 1 <= 12`.
- Seeded: `found` = 1 iff at least one SPECIFIC `defect` finding on the defect file overlaps
  `[start-3, end+3]`. `false_positives` = distinct (file, `line_start`) pairs among `defect` findings
  on code files that do not overlap that window (a wide finding overlapping the window is neutral:
  no credit, no FP; a wide one elsewhere is an FP). PASS iff `found == 1`, `false_positives <= 5` and
  the tree is unmodified.
- Clean: `false_positives` = distinct (file, `line_start`) pairs among ALL `defect` findings on code
  files, specific or not. PASS iff the document is valid, `false_positives == 0` and the tree is unmodified.
- `non_defect_findings` counts the other three classes on code files; `nonspecific_findings` counts
  findings wider than 12 lines (any class). Both are informational.
- Each `task.json` carries `"kind": "seeded" | "clean"`; the report gives a verdict per kind.

## Modification rule (`expected.diffhash`)
`tree_hash` covers: every TRACKED file (content, including context files and any file type; a
deleted tracked file counts), the porcelain status of tracked paths, and EVERY untracked file in any
language or with no extension. Not counted: paths the fixture's own `.gitignore` ignores (git omits
them from the status: Rust `target/`, Python `__pycache__/`) and untracked host droppings:
`.claude/`, `.codex/`, `.agents/`, `CLAUDE.md`, `AGENTS.md`. A fixture whose normal build or test run
writes files into the work tree must therefore ignore them in a tracked `.gitignore`. Regenerate after touching a
fixture or setup patch: `_lib/regen_expected.sh <task-dir>` (copies `fixture/` to a scratch repo,
commits, runs `fixture.setup.sh`, hashes).

## Adding a task
Directory `<kind>-NN-<slug>/` with: `fixture/` (a tiny Go module, `go.mod`, `production.yaml`,
`.prod/context/{resolved-context,change-plan}.yaml`), `fixture.setup.sh` (applies the uncommitted
change; regenerate it from a scratch `git diff`, never by hand), `grade.sh` (copy a sibling, set
`--file F --start N --end M` for a seeded task from the POST-change line numbers, or `--clean`),
`reference/solve.sh` (writes a valid document a correct reviewer returns; for a clean task it must
include a non-defect finding), `task.json` (same prompt string as every task, plus `kind`),
`README.md` (the change, the defect or why it is clean, the real pass rule), `expected.diffhash`.
Then `go build ./... && go vet ./... && go test ./...` in a scratch copy, `gofmt -l` empty, and a
scratch test that reproduces the defect at the failing line.

## Context artifacts (one convention for all twelve tasks)
Both authors' styles must not be a tell, and a faithful `prod-review` run recomputes the
events from the diff, where an undeclared event is a DIVERGENCE BLOCKER. So the fixtures follow one rule:
- `semantic_events` lists every event the change actually causes, per `prod-spec` step 5.
  `changes_public_api` for an added or changed exported identifier, route or wire shape (with
  `compatibility.api` additive or breaking); `changes_critical_calculation` for money or token-count
  arithmetic; `introduces_state` for a NEW type that keeps data across calls (a map, cache or
  accumulator), declared together with `new_states` and a `recovery` entry; `introduces_retry`,
  `introduces_queue`, `changes_hot_path` only when the change introduces one (none do: the retry
  loop, the batch buffer and the limiter already existed, and no task declares a load baseline);
  `none` only when no event applies (seeded-08 changes where a lock is held, nothing else).
- `capabilities`: none. Every module is a library whose `production.yaml` says the callers own
  persistence, transport and operations, so `capabilities: []`, `touched: []`, `obligations: []` everywhere.
- `zone`: `core` for pure computation (split, parse, cursor paging), `orchestration` for locks,
  clocks, goroutines and stores, `shell` for the HTTP handler and the file/env loader.
- Comment density of the uncommitted change is kept in the same range (3-6 comment lines) for both kinds.

## What the grader cannot see
It trusts the reviewer's own `class`. A reviewer who files the real defect as a `note` has not
flagged it (found 0, by design). A reviewer who never looks at the code can pass a clean task, which
is why recall (`found` on seeded) and false positives (clean) are reported separately and never
averaged. It does not judge whether a `defect` is correct, only where it points, and a line range
inside the window is accepted whatever the summary says.

## Selftest
`_lib/grade_findings-selftest.sh` (wrapper over the in-process `grade_findings_selftest.py`, ~2 s)
runs the named cases (prints `N/N passed`, exit 1 on failure, 2 on zero cases). It also checks
that `output.schema.json` stays inside the portable subset (strict objects with `required` listing
every property, no `$ref`/`oneOf`/`anyOf`/`format`/`pattern`/`minItems`/nullable) and that every
`reference/solve.sh` output validates, and drives three real tasks through their `grade.sh`.
`GRADE_PY=<copy>` grades with another copy of the grader; `--mutations` mutates a temp copy
ten ways (window slack, class check, severity, FP cap, width cap, context, modification, verdict
consistency, schema strictness, distinct counting) and prints one `RED` or `GREEN` line each.
