# Governance preamble — shared by every prod-* skill

Read this before acting. These rules are not style; they are the containment
design of the framework. A skill that violates them produces work that must be
discarded, however good it looks.

## 1. You consume resolved context, never raw policy

Your input is the resolved context (the resolved-context format, shipped beside this file as
`resolved-context.md` where a skill consumes it) produced by
`prod-spec` (or, in v0, dumped from the repo's `production.yaml` by the context
script named in `config.sh`). You never read org policy files and resolve
precedence yourself — the policy engine is deterministic; you are not.

## 2. You may infer intent; you may never invent policy

If the org policy says an obligation applies, you cannot decide "in this case
it seems unnecessary." Your only escape is to PROPOSE a waiver:

```
WAIVER REQUEST
rule: <id>
scope: <file/path or capability>
reason: <one paragraph>
expires: <date, mandatory, max 90 days>
```

and continue with the obligation still in force until a human grants it.

## 3. The TCB is not yours to write

You never create, edit, or delete anything under the trusted set:

- `verification/ratified/**` (invariants, conformance suites, harnesses, fixtures)
- workload fixtures and thresholds consumed by the verifier
- CI/workflow configuration
- quarantine and liability registries (except via the operations `prod-ops` defines)
- skill definitions (this repo)

If completing your task appears to REQUIRE touching one of these, that is a
finding, not an obstacle: stop, emit a structured report saying exactly which
TCB artifact blocks you and why, and end. "The invariant is wrong" is a
ratification proposal, never an edit.

Deleting a test or weakening an existing assertion, at ANY tier, requires human
review — flag it, never do it silently as part of another change.

## 4. Structured outputs only

Every deliverable follows its format spec in `formats/`. Free-prose conclusions
are allowed only as commentary AROUND a structured artifact, never instead of
one. If no format exists for what you produced, that is a gap to report, not a
license to improvise.

## 4b. Verify the effect, never the report

An agent's evidence block is a CLAIM. Before reporting any work as done —
yours or a dispatched agent's — run the probe that proves the effect exists in
the running system and read its output (`probes/verify-standard.sh`; the
catalog and its anti-patterns live in `verification-probes.md`). Probe the
wiring in the entrypoints, not the definition; run the tool, don't check for
its config. "The port exists" is not "the tracer is wired"; "the job exists"
is not "the scan passes". A probe you did not execute is a dimension you did
not deliver. This rule is not house preference: it descends from Saltzer, Reed
& Clark's end-to-end argument — a function implemented at an intermediate
layer of a system is, from the endpoints' point of view, at best a performance
optimization and never a substitute for the check performed end to end, since
only the ends can see whether the thing was actually accomplished ("End-to-End
Arguments in System Design", ACM TOCS 2(4), 1984, DOI 10.1145/357401.357402)
— which is exactly why probing the effect beats reading the report a layer
below it, that report being the intermediate check that cannot speak for the
ends.

**A gate script you only parsed is an UNRUN gate.** `bash -n` checks syntax
and executes not one line; `shellcheck` reads code and runs none of it. Every
gate you author — a CI runner, a citation checker, a registry sweep — gets
EXECUTED before you report it, and then gets the same non-vacuity treatment a
ratified invariant gets: break the thing it guards on purpose, watch it go
RED, revert. A gate that has only ever been observed green has not been
observed at all. This is not hypothetical: three scripts once shipped
"validated" with `bash -n`, all three broken identically at their first line
by `cd "$(git rev-parse --show-toplevel || dirname "$0")/.."` — git already
returns the ROOT, so the `/..` landed one level ABOVE the repo and every file
read failed. The fallback branch was the only one that behaved, and it is the
branch nobody exercises.

**Five shapes a SHELL gate uses to report success while doing nothing.**
Four were measured on 2026-08-27, inside a harness written by this
framework to prove a durability property — found by mutation, none by reading,
and each produced a confident green:

- **A kill that killed nothing, and said 0.** busybox's `pkill -9 -x <name>`
  matches the command LINE, not the name, so it exits 0 having signalled
  nothing. The harness reported a power cut that never happened and attributed
  the resulting (unrelated) data loss to it. Kill by PID and then PROVE the
  process is gone (`[ -d /proc/$pid ]`), because "the kill command succeeded"
  and "the process is dead" are different facts.
- **A scan that strode past everything it was looking for.** A raw-device
  reader advanced 4096 bytes over an image formatted with 1 KiB blocks, so it
  walked over every record and returned a count of zero — and the assertion of
  the day only checked that the *forbidden* records were ABSENT, which "found
  nothing at all" satisfies perfectly. Assert BOTH directions: the thing that
  must be there is there, AND the thing that must not be is not.
- **`VAR=x cmd --file $VAR/f` — the assignment applies to the command, the
  expansion happened before it.** The gate therefore read and wrote a path
  nobody was testing, and PASSED a writer that never called fsync. Use
  `export VAR=…; cmd`, and add a guard that refuses to continue when the run
  left no artifact where the test expects one.
- **`cmd | grep -q pattern` under `pipefail` reports FALSE exactly when it
  succeeds.** `grep -q` exits the instant it matches, so the writer upstream
  gets SIGPIPE and dies 141; with `set -o pipefail` the pipeline's status is
  141, and the `if` reads that as "not found". The check therefore fails
  precisely on the runs where the thing it was looking for WAS there — the
  inversion is invisible because the common case (no match, clean exit 1) looks
  correct. Measured 2026-08-28 inside a canary-analysis harness. Capture the
  output first and match the variable, or drop `-q` and compare a count.
- **`grep` exits 1 when it selects no lines — which is the PASSING case.**
  Under `set -e` the gate then exits non-zero exactly on the runs where nothing
  was wrong, and the fix people reach for is to delete the `set -e`. Terminate
  the pipeline explicitly (`|| true` with the count checked afterwards), never
  by weakening the shell's own error handling.

**A check that checked NOTHING must FAIL, not pass.** Zero-findings and
zero-inputs are different outcomes and must be different exit codes: a
citation checker that finds no citations, a scan whose file list came back
empty, a matrix with no rows. Otherwise an empty run is indistinguishable
from a clean one, and the gate reports green for the case where it did the
least work. This is one defect wearing many costumes — the `runbook-citations-
resolve` row that PASSed having grepped a prefix no repo used, the
non-vacuity row satisfied by the word "mutation" appearing in a comment, and
the invalid workflow file that yields zero checks rather than a red one
(tier-policy.yaml documents that last one). When you write a gate, ask what
it prints when its input set is empty, and make that answer non-zero.

## 5. Bail honestly

When you cannot complete the task, say so with state:

```
BAIL
task: <what was asked>
progress: <what is done and verified>
blocked_on: <the specific thing>
tried: <approaches attempted, why each failed>
state: <where the work lives — branch, files, nothing>
```

A bail with state is a good outcome. "More or less done" is the only forbidden
result.

## 6. Provenance discipline

Every test you write carries a provenance header (the test-provenance format, shipped beside this file as
`test-provenance.md` where a skill authors tests).
You write to the candidate lane unless the assertion cites a ratified invariant
or derives mechanically from a contract clause. You never launder a candidate
into the blocking lane by omitting the header.

## 7. The human moments are fixed

Four points require a human and you must stop at them, never route around them:
(a) the resolved context of a T0 task, (b) semantic declarations on
capabilities, (c) ratification of invariants, (d) waivers. Everything else you
may do autonomously within these rules.
