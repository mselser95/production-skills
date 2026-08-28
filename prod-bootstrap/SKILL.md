---
name: prod-bootstrap
description: >
  Interactive onboarding skill: bring a repo "to standard" — inventory it
  against the production-verifiability framework, ask the human the semantic
  questions only they can answer (tier, capabilities and their classes, seed
  invariants, source of truth, latency budget, gate commands), then scaffold
  the spec and directories, emit an honest gap report (requirement → current
  state → severity), and produce a RATCHET-style refactor plan in change-plan
  format — bounded tasks routed to prod-implement, never a big-bang rewrite.
  The human is present and answering throughout; this is the one skill in the
  suite that is conversation-first.
  TRIGGER when: a repo is being onboarded to the standard ("bootstrap this
  repo", "bring X to standard", "set up production.yaml for this service",
  "what does this repo need to comply?"), for greenfield and brownfield alike.
  DO NOT TRIGGER when: the repo already has a production spec and the ask is a
  task against it (prod-spec), or the context is headless (CI, cron,
  non-interactive runs) — the Q&A requires a present human; bail instead of
  guessing semantic answers.
---

# prod-bootstrap — bring a repo to standard

Read `references/preamble.md` first, and `references/mechanism-derivation.md`
before Phase 1b (which mechanisms this service warrants — the inventory shows
what it HAS, the derivation says what it should have). If
`_shared/domain-topology.yaml` exists, also read `references/domain-
boundaries.md` before Phase 1b — same phase, one more thing to check for.
Outputs use `references/resolved-context.md` conventions for the spec fields
and `references/change-plan.md` for the refactor plan. Registry and path
names come from `config.sh`.

Three rules frame everything:

- **DERIVE, DON'T INTERROGATE.** Every threshold, obligation, scenario list,
  and plan task comes from `references/tier-policy.yaml` (org decisions, made
  once) and `references/dimensions.md` (the completeness checklist). The human
  is NEVER asked for a number, a checklist, or anything a class implies. If
  you find yourself about to ask "what coverage threshold do you want?", the
  policy file already answered it.
- **ONE batched confirmation, defaults pre-filled.** The only human-only input
  is irreducibly semantic: the tier (proposed from consequence), the
  capability set + their semantics (proposed from the inventory), the "what
  must never happen" invariants, and any declines. Present them together with
  your proposal for each so a single "yes" completes the bootstrap. Silence or
  "dale" = accept the proposal; never block on a question whose default is
  already sound and reversible.
- **The plan is a ratchet, never a rewrite.** Brownfield repos get compliant
  at the frontier (new/changed code) plus a leverage-ordered backlog; nothing
  in the plan blocks current work on day one.

## Contract

- **Input:** the target repo checkout + a present human.
- **Output:**
  1. `production.yaml` (spec-lite: `{tier, invariants[], capabilities[]}`),
     each entry human-ratified;
  2. scaffolded directories: `verification/ratified/` (empty skeleton +
     README), `<PROD_REGRESSIONS_DIR>/`, `PROD_RATIFY_QUEUE_DIR`, the
     liability registries (empty, with headers);
  2b. the repo's **`AGENTS.md`** instantiated from
     `references/agents-template.md` — the routing contract that makes EVERY
     future agent request in this repo pass through the pipeline
     (spec → implement → review) and validate against the standard; merged,
     never overwritten, if one already exists;
  2c. the **failure-mode matrix** (`.prod/failure-modes.md`), auto-expanded
     from each declared capability's class checklist in tier-policy.yaml,
     with every scenario marked tested / untested / not-applicable;
  3. the **gap report** (format below);
  4. the **refactor plan** in change-plan format, tasks tagged
     `ambiguity: none|low|open`, ordered by leverage;
  5. per-skill `config.sh` value suggestions for this repo (gate commands,
     paths) — printed, not written to skill dirs;
  6. **the implemented work itself** (Phase 6): branches/commits closing every
     non-open gap, consolidated into one PR with its gates green.

## Algorithm

Dispatch per `references/dispatch.md`: Phase 1 runs on a `prod-scout` agent
(cheap, read-only, checklist in / facts report out); phases 2–5 stay on the
session model with the human.

### Phase 1 — Inventory (read-only, no questions yet)
Detect and record, without judging:
- language/build layout; entrypoints; package structure vs the three zones
  (is there a pure core? where does I/O live?);
- external boundaries: every outbound client, DB, queue, stream, scheduler
  found in the code — each is a CANDIDATE capability with a guessed class;
- existing spec artifacts (`PROD_SPEC_FILE`?), test layout (any provenance
  convention? any advisory lane?), CI stages (is there a cheap gate? what
  runs on PR vs nightly?), fitness checks (import bans, forbidden calls),
  clock/random/ID injection vs direct calls in core paths, outbox/journal
  patterns on external effects, reconciliation jobs, registries.

### Phase 1b — Derive everything derivable (no human involved)
Before formulating a single question, resolve from the policy files:
- tier requirements, thresholds, and gate/signal/trend labels →
  `references/tier-policy.yaml` (`tiers.<k>`);
- per-capability obligations AND the scenario denominator →
  `tier-policy.yaml` `capability_classes.<class>` (checklists are the
  denominator; the author never supplies scenario lists);
- which dimensions need a gap row and which need a human answer →
  `references/dimensions.md`;
- **whether `_shared/domain-topology.yaml` exists** — if not, dimension 24 is
  NA for this repo and every domain-aware step below is skipped, silently,
  for the rest of this run. If it exists, propose `owning_domain`/
  `domain_role` from the inventory's external-boundary list against the
  topology's own entries, and for each candidate capability that reaches
  another domain, propose whether it should resolve through that domain's
  `domain_gateway` (`references/domain-boundaries.md`);
- **which architectural mechanisms this service warrants** →
  `references/mechanism-derivation.md`, run against the Phase-1 INVENTORY
  rather than a purpose line, since the code already shows what exists.
  **Brownfield is where §8's tracing derivation is at its strongest**, because
  its inputs are repo signals — listeners, registered routes, declared ports,
  the shape of the work loop — and here they are all present to read. Derive
  the verdict; put it to the human only if the signals contradict each other
  (the usual case being a consumer that also exposes an admin endpoint);
- the cheap-gate and presubmit commands → read the repo's build files;
  propose, don't ask.
Anything still unresolved after this step is either a Phase-2 semantic
question or a Phase-1 inventory gap you must go back and fill.

**The derivation produces two lists here, and they are worth more than either
alone.** Brownfield is the only place both are visible:

- **warranted but ABSENT** — real gaps. Each becomes a gap-report row in Phase
  4 and a plan task in Phase 5, like any other unmet obligation.
- **PRESENT but not warranted** — ceremony the repo is already paying for: an
  outbox nothing external needs, an event log over state that is just arbitrary
  writes. Report these as PROPOSALS with the property that produced them, never
  as automatic removal tasks. Deleting working machinery is a bigger decision
  than adding some, the repo may know something the derivation does not, and
  preamble §3 keeps you out of existing code regardless.

Both lists carry the property that decided them, so a reader can disagree with
the reasoning rather than just the conclusion.

**If a removal proposal is ever accepted, price it honestly.** The derivation
reference's "What removal actually costs" section classifies each mechanism as
**package + wiring**, **wiring only**, or **declaration only**, and lists the
nine kinds of debris a package-shaped removal leaves — including the two that
fail LATER and blame something else: a stale line in the coverage floors reads
as a coverage regression, and a `Makefile` name-guard fails loudly for a fuzz
or e2e target that is deliberately gone. A removal task that stops at deleting
the directory produces a red repo whose redness points somewhere useless.

**Brownfield is where package-shaped removal is actually executable**, and it
is worth knowing why. `prod-new` cannot yet scaffold a non-event-sourced
service by omission, because the template's own example IS a fold across three
layers. Here there is no template example — the repo's domain is whatever it
already is — so the mechanism really is separable from it. That asymmetry is
recorded in the derivation reference; do not carry `prod-new`'s blocker over
to a repo it does not apply to.

### Phase 2 — ONE batched confirmation (proposal-first)
Present a single message containing your PROPOSAL for each item below, each
with its evidence, phrased so that "yes/dale" completes it. Never a
question-per-item interrogation; never a question whose answer the policy
already holds.
1. **Tier** — proposed from consequence (irreversible external effects +
   unreconstructable data integrity ⇒ T0; feeds a T0 consumer ⇒ T1 with the
   T0 invariant-flake rule; else T2), with the evidence that drove it.
2. **Capabilities** — the inventory's candidate list with class assignments
   AND the class-implied semantics pre-filled; the human confirms or corrects.
   Detected-but-declined candidates are recorded as explicitly out of scope.
   **Where the topology file exists**, this item also carries Phase 1b's
   `owning_domain`/`domain_role` proposal and the `domain_dependencies`
   candidates, in the SAME batched message — never a separate question.
   Absent, this paragraph does not apply and nothing is asked.
3. **Invariants** — the one genuinely open question: "what must never happen
   in this system?" Seed it with candidates you inferred from declared
   metrics, doc invariants, and the code's own fail-closed checks, so the
   human is editing a list rather than authoring one. These become packages in
   `PROD_RATIFY_QUEUE_DIR` (ratification is its own later moment — bootstrap
   never writes `verification/ratified/`).
4. **Declines** — anything the inventory suggests is N/A for this system
   (e.g. reconciliation where no durable state exists), each with the
   rationale that will be recorded in `out_of_scope`. Where a decline comes
   from Phase 1b's derivation, quote the PROPERTY that produced it rather than
   restating the conclusion: "no outbox — every declared capability is
   source_of_truth or external_read, so nothing leaves this process that a
   crash could lose" is a decline a future reader can check against the
   capability list. "No outbox — N/A" is one they can only trust.
Everything else — coverage numbers, mutation policy, fuzz requirements,
scenario lists, benchmark policy, security gates, delivery/runbook
requirements — is DERIVED and merely REPORTED in the gap report. Do not ask.

### Phase 3 — Scaffold

**`chmod u+w` anything copied out of the installed skill directory.** The
installed TCB is read-only (install.sh leaves it that way so an incidental write
fails loudly instead of silently), and `cp` preserves mode — so a template
copied into the target repo arrives read-only and the very next edit to fill its
slots fails with EACCES. Copy, then make writable, then fill.

Write the spec, directories, and the AGENTS.md routing contract (Contract
output 1–2b) — every `<slot>` in the template filled from a ratified Phase-2
answer, per the template's instantiation rules. Everything written is
additive — bootstrap never edits existing code, tests, or CI config
(preamble §3 applies; CI wiring for new lanes is a plan task for a human or
prod-implement under review, not a bootstrap side effect).

### Phase 4 — Gap report (completeness-enforced)
Walk `references/dimensions.md` and emit a row for EVERY dimension — all of
them, whatever the file currently lists (it has grown, and a count hardcoded
here would silently retire whichever dimension was added last),
every sub-item each dimension's "Row:" line names. A missing row is a broken
bootstrap, not a shorter report.

```
GAP REPORT — <repo> (tier T<k>)
| dimension | requirement (from policy) | current state | gap | severity |
```
Also emit, as their own rows because they are the ones humans forget:
coverage today vs the tier signal, **tests/prod LOC ratio (informational)**,
mutation baseline, fuzz coverage of decode boundaries, the failure-mode matrix
completeness per capability, integration fidelity (any real dependency?),
compatibility/breaking-change detection, benchmark baseline + capacity margin,
recovery/reconciliation/restore, observability contract, every supply-chain
gate, and delivery/rollback/runbooks. Three more, each of which hid a live
defect for weeks and each of which is one cheap read: for every gate the spec
calls BLOCKING, whether its check context is in the repo's REQUIRED contexts
(from the forge, never from the workflow file — `references/dimensions.md`
§10); every declared surface that no reconciler applies, with its apply
procedure and owner (§10); and every declared backend paired with the producer
that ships to it, or the fact that it has none (§8).
Severity is impact-based for the tier. Nothing is omitted for being
embarrassing, and "not applicable" is a legal state ONLY with its reason.

**A gap whose mechanism this org has never run is a demo before it is a plan
task.** `demos/INDEX.md` lists the properties already made executable and the
vehicle each travels by ([A] per repo, [B] once per org). A [B] row is not a
repo task at all — the repo only owes participation in a control installed
elsewhere, and writing it as a per-repo task produces a plan the team cannot
execute.

### Phase 5 — Refactor plan (the ratchet, auto-populated)
Every dimension whose Phase-4 row shows a gap MUST produce a task — the plan
is generated from the gap report, not from recollection. Baseline task set,
ordered by leverage:
1. fitness checks (import bans, forbidden calls in core) — days of work,
   permanent payoff, zero behavior change;
2. clock/random/ID injection on critical paths;
3. extract the first pure decision core (the highest-risk calculation);
4. outbox/journal on external effects + table-driven recovery tests;
5. provenance headers + advisory lane wiring;
6. seed the incident-fixture corpus from the last known incidents;
7. reconciliation job for the primary source-of-truth pair;
8. fuzz targets on every decode/parse boundary (checked-in seed corpus,
   wired into the repo's fuzz lane);
9. mutation advisory baseline over the core packages (TREND, never a gate);
10. benchmark baseline of the hot path with a versioned workload (relative
    regression only — SIGNAL);
11. open-loop load baseline + soak lane (dimension 25) — `benchmarks/load/baseline.md`
    with the MEASURED saturation point, wired as `make load` / `make soak`.
    Item 10 measures the delta, this measures the ceiling: a relative check on
    a hot path nobody has driven to saturation reports a healthy percentage
    right up to the knee, and the soak lane is the only one of the two that
    can see a degradation whose unit is hours.
This list is the MINIMUM: a plan that omits any dimension without an
explicit declined-with-rationale entry is an incomplete bootstrap — the
human should never have to ask "where is the fuzzing?". Tasks a cheap model
can do are tagged `ambiguity: none` and handed to `prod-implement`; design
decisions stay `open` with the human. State explicitly which gaps the plan
does NOT cover and why.

### Phase 6 — EXECUTE (the default; planning alone is not a deliverable)
A gap identified and left as a plan item is a bootstrap that did half its job.
Every task from Phase 5 whose `ambiguity` is `none` or `low` is DISPATCHED and
driven to completion in this same run, per `references/dispatch.md`: one
`prod-implementer` per task in its own git worktree branched from the default
branch (parallel where independent), `prod-mechanic` for the mechanical
baselines. What is missing gets BUILT — the scenario tests for every untested
checklist entry, the fuzz targets on every decode boundary, the mutation
baseline, the missing security gates, the benchmark baseline and its versioned
workload, the tracing/observability wiring, the integration lane, the
compatibility check, the runbooks.

Rules for this phase:
- **Only `ambiguity: open` reaches the human**, and only as a decision with a
  recommendation ("adding a tracing dependency to a 3-dependency repo — port
  with a no-op default, or the full library?"), never as a chore to schedule.
- Additive capabilities the repo lacks entirely (event sourcing / replay
  corpus, effect journaling, reconciliation, tracing) are IMPLEMENTED when the
  dimension's policy says required for the tier — unless the system's ratified
  semantics make them N/A (no durable state ⇒ reconciliation N/A), which is a
  recorded decline, not a silent skip.
- Each dispatched task lands as its own commit on its own branch; the
  orchestrator consolidates into ONE pull request unless told otherwise, runs
  the gates on the consolidated result, and reviews the diffs against their
  contracts before opening it.
- **Completion gate:** run `references/probes/verify-standard.sh` and make its
  output the report. A dimension is done when its probe passes; a probe that
  fails is a finding you fix or declare, never a line you soften. You may not
  claim completion from the dispatched agents' evidence blocks — probe the
  effect yourself (preamble §4b).
- Report at the end: the probe table, what was declined with its reason, and
  the short list of open decisions — nothing else should be left for the human
  to remember.

## Toolchain support — check this BEFORE promising a gate

`_shared/probes/verify-standard.sh` implements the **Go** toolchain only. About
sixty of its lines are `go build ./...`, `go test`, `--include='*.go'`,
`//go:build` tags, golangci-lint and Go coverage profiles.

It now REFUSES to run on anything else (`PROD_LANG` detection, exit 2) rather
than emitting rows that measure its own blind spot. Measured against a C++/CMake
repo with the guard disabled: `PASS 3  FAIL 52  NA 2`. Fifty-two rows saying
nothing about the code, and the one real finding among them unfindable.

So on a non-Go repo, phase 1 of this skill still works — the inventory, the
Q&A, the gap report and the plan are language-agnostic, and so is most of the
standard (liability registries with owner+expiry, the scenario matrix, runbook
citations that resolve, SLOs, observability contracts, ratification packages,
workflow validation, secret scanning, SBOM, the per-commit evidence record).
What does NOT exist yet is the executable gate.

**Do not scaffold a `scripts/verify-standard.sh` into a non-Go repo.** A vendored
probe that refuses to run is a gate the repo believes it has and does not. Say
so in the gap report as its own row, at the severity it deserves, and make the
toolchain a plan task.

Adding a toolchain means giving it the equivalent of every language-bound row —
build, unit tests, race (TSan for C++), coverage plus the per-package ratchet,
lint (clang-tidy), fuzz (libFuzzer), benchmarks (google-benchmark) — and wiring
them in. A row with no equivalent becomes an explicit, ratified N/A with a
reason. Never a silent skip: that is the one change that would make the probe
worse than absent.

## Guardrails

- Preamble in full. Bootstrap-specific:
  - Every semantic fact in the spec traces to a human answer from Phase 2 —
    the artifact records ratification, like a resolved context does.
  - Never block the repo's current work: nothing in the scaffold turns any
    existing check red on day one; new gates arrive via the plan, warn-first.
  - If the human is absent or answers stall, park everything produced so far
    in a branch and BAIL with state — a half-ratified spec is not a spec.

## Field notes — five repos, one session (2026-08-23)

Every line below was paid for once. None of it is theory.

### The warn-first gate, without creating a fail-open

A bootstrap installs a gate that measures ~30 real failures on day one, and the
guardrail above forbids reddening anything. That is a fail-open by
construction, so build it honestly:

- **The job NAME says it gates nothing** (`verify-standard-report-only`).
  Hiding `continue-on-error: true` behind a reassuring name is the defect.
- **Register the fail-open as debt with an owner and an expiry**, and make the
  expiry redden something that ACTUALLY BLOCKS — the registry checker runs in
  the REQUIRED lane, so a lapsed entry turns a required check red on its own.
  Without that, the "temporary" report is permanent and nothing notices.
- **Never `|| true` to make the check green.** A green check over a failing
  probe is a fail-open that also LOOKS clean, which is strictly worse.
- **`continue-on-error: true` does NOT render the check neutral.** Measured:
  the PR list shows a red X and `gh pr checks` reports `bucket=fail`. It does
  not block, but a reviewer sees red — so the PR body MUST say the red is
  expected and why, or the work reads as broken.

### Measuring the baseline

**Never measure the "before" in the working repo after vendoring the probe.**
The before-tree then contains part of the after, and the probe's own file is
exactly what makes some rows pass. Use a clean worktree of the base branch.
This was caught in review on one repo and had silently inflated its reported
improvement by a row.

### Do not re-author the selftests

Vendor `_shared/probes/non-vacuity-selftest.sh`. Three repos wrote their own in
one session and all three shipped the SAME defect — a control case asserting
with `grep -qF ""`, which matches every input, so the control of the
non-vacuity checker was itself vacuous in both directions.

### CI jobs a bootstrap adds

- **Pool**: anything that does not talk to a Docker daemon belongs on the
  medium pool. `clc-ci-large` is 3 nodes at one runner each, org-wide; parking
  non-docker work there starves the fleet. One repo's bootstrap copied the
  local pattern and put three jobs on a three-slot pool.
- **`timeout-minutes`**: declare it. Measured, the full probe takes 19-29 min
  on a ~1 vCPU runner; with no bound the job inherits GitHub's 6-hour default,
  and while it runs it BLOCKS `gh run rerun --failed` for every other job in
  that workflow.
- **Lint budgets**: a `timeout: 5m` over a lint that takes 25s warm is not the
  margin it looks like — the budget covers package LOADING, which any cache
  invalidation blows.

### A toolchain bump is not a one-line change to CI

Changing go.mod's `go` directive invalidates `actions/setup-go`'s cache key, so
the FIRST run recompiles everything. Measured on one repo: every job 2-4x
slower and lint timing out at 5m01s, then **25s** on rerun with a warm cache.
Before touching any config when a bump reddens CI, compare job durations
PR-to-PR: if EVERY job slowed, it is the cache, and a rerun is the experiment.

Separately: **a vulnerability count is a property of the toolchain.** Same tree
measured 22 / 6 / 0 called vulnerabilities under go1.26.0 / .5 / .6, and CI
installs whatever literal sits in go.mod. Never quote a count without naming
the version beside it — the probe's `vuln-scan` row now does this and flags a
mismatch between the running toolchain and the pinned one.

## Bail

Preamble format. Expected `blocked_on` values: `headless` (no human present —
this skill never guesses semantics), `spec-exists` (repo already has one —
point to prod-spec), `answers-stalled`.
