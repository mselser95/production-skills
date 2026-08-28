---
name: prod-incident
description: >
  Orchestrator skill: convert a production incident into executable knowledge —
  a minimized replay fixture asserting invariants (never golden state), a
  candidate invariant package with mandatory evidence in BOTH directions plus a
  contradiction-check against declared capability contracts, a missing-signal
  report (what was indistinguishable in prod that shouldn't be), and a
  gate-attribution line (would any declared gate have caught this?). This is
  the level-5 feedback loop of the evidence ladder: reality is the one oracle
  agents cannot game.
  TRIGGER when: an incident is being closed out ("turn this incident into a
  fixture", "materialize the regression for X", post-incident analysis is done
  and its knowledge must become permanent verification).
  DO NOT TRIGGER when: the incident is still being actively debugged (this
  skill consumes a finished analysis, it does not page through live systems),
  or the user wants the live investigation itself (use the org's
  debugging/on-call skills).
---

# prod-incident — from incident to permanent verification

Read `references/preamble.md` first. Output format:
`references/incident-fixture.md`. An incident close-out that produces only a
fix is a discarded lesson.

Dispatch per `references/dispatch.md`: log/trace sweeps and minimization
search runs can go to `prod-scout`/`prod-mechanic`; the analysis, the
candidate invariant, and the gate attribution stay on the session model.

## Contract

- **Input:** the incident's finished analysis — timeline, logs/traces, the
  culprit change if known, the fix if merged — plus the affected repo(s).
- **Output:** ALL FOUR artifacts, every time:
  1. minimized fixture under `<PROD_REGRESSIONS_DIR>/<yyyy-mm-dd>-<slug>/`
     (default `regressions/`);
  2. candidate invariant package → written to `PROD_RATIFY_QUEUE_DIR`
     (default `.prod/ratify-queue/`), NEVER into `verification/ratified/`;
  3. missing-signal report (same queue dir, same proposal file);
  4. gate-attribution line.

## Decision rules (these override everything else)

- **RULE TWO-COLORS:** a fixture is valid only when demonstrated BOTH ways —
  red on the pre-fix commit, green on fixed code. A fixture that never turned
  red proves nothing; a close-out missing either color is incomplete, and you
  say so rather than accept it. **A fixture not yet shown RED is not written
  into `<PROD_REGRESSIONS_DIR>/`** — a permanently-green fixture is corpus
  noise indistinguishable from a working guard, and the corpus is the one
  place this framework cannot afford decoration. Park it in
  `PROD_RATIFY_QUEUE_DIR` with the color it is missing named, and it enters the
  corpus when somebody produces the red.
- **RULE NOT-REPRODUCIBLE:** if the failure cannot be reproduced after real
  minimization effort, the close-out does NOT stall and does NOT get waved
  through. **The four-artifact contract still holds, re-expressed** — "become"
  in the old wording read as "the other two are dropped", which is the reading
  that turns an irreproducible incident into a two-artifact close-out nobody
  audits:
  1. no fixture directory is committed; a `simulability-gap.yaml` in
     `PROD_RATIFY_QUEUE_DIR` takes its place, naming what the harness lacked;
  2. the candidate invariant is still proposed where the incident implies one —
     an unreproducible failure can still have taught you what must never
     happen, and it is filed with its evidence gap stated rather than withheld;
  3. the missing-signal report and (4) the gate attribution are unchanged and
     are now the load-bearing ones.
  "Irreproducible" is never a way to skip the work; it changes which artifacts
  are the deliverable, not how many.
- **RULE SHELL-INTERLEAVING:** if the failure lived in shell-level
  interleavings (retries, timeouts, crash windows), model the shell's part as
  explicit events (effect-result events, timeout events) so the core replay
  exhibits it. If that modeling is impossible, apply RULE NOT-REPRODUCIBLE —
  the simulability gap is itself the finding.
- **RULE NO-RATIFIED-WRITES:** candidate invariants and conformance material
  are PROPOSALS into `PROD_RATIFY_QUEUE_DIR`. You never write into
  `verification/ratified/` — however strong the invariant looks (preamble §3).
- **RULE NO-CI-EDITS:** you never edit CI/workflow configuration. Place the
  fixture where the advisory replay job discovers it
  (`<PROD_REGRESSIONS_DIR>/`), verify both colors LOCALLY; if CI does not yet
  run the replay corpus, that is a finding for a human, reported in the
  close-out — not a workflow edit.
- **RULE SPARSE-INPUT:** if the analysis material is too sparse both to
  reproduce AND to identify missing signals → BAIL listing exactly what is
  missing (which log window, which trace, which config version).

## Algorithm

1. **Reproduce minimally.** From the analysis, construct the shortest event
   sequence exhibiting the failure against the pre-fix code. Target 10–50
   events — minimization is the deliverable; a raw capture is fixture rot on
   a timer. Apply RULE SHELL-INTERLEAVING / RULE NOT-REPRODUCIBLE as needed.
   The systematic form of this reduction is **ddmin** (Zeller & Hildebrandt,
   "Simplifying and Isolating Failure-Inducing Input", IEEE TSE 28(2), 2002):
   split the sequence into n chunks, test each complement, keep whatever
   still fails, raise the granularity when nothing does. You MAY run it
   mechanically when the raw capture is large — the replay harness is already
   the pass/fail predicate ddmin requires, so the search is a script and not
   a judgment call, and it converges on a sequence that is 1-minimal
   (removing any single event makes the failure disappear) rather than one
   that merely stopped shrinking when you got bored. Record the predicate you
   minimized against: a ddmin run against "the process exits non-zero"
   minimizes toward the wrong failure and produces a fixture that passes for
   a reason nobody stated.
2. **Assert invariants, not snapshots.** `invariants.txt` names which
   ratified invariants must hold at every transition of the replay. If the
   incident violated something no ratified invariant captures — that IS the
   candidate invariant.
3. **Build the candidate invariant package** (format spec, all fields):
   evidence in BOTH directions — N passing runs on fixed code AND the
   concrete violating trace (usually the fixture itself). Run the
   contradiction-check against declared capability contracts: a candidate
   contradicting a declared clause (e.g. "exactly once" vs
   `may_be_duplicate: true`) means the candidate is wrong or the contract is
   — flag the CONFLICT explicitly; never propose past it silently.
4. **Missing-signal report.** For each behavior that was invisible or
   ambiguous in production telemetry: what it looked like, what would have
   distinguished it, the proposed metric/attribute/event.
5. **Gate attribution.** One honest paragraph: which declared gate would have
   caught this before production — or none, and why. Write it even when
   (especially when) the answer is embarrassing.
6. **Verify and place.** Both colors demonstrated locally (RULE TWO-COLORS);
   fixture directory complete (`fixture.yaml` with `schema_version`,
   `events.json`, `invariants.txt`); proposals in the ratify queue; RULE
   NO-CI-EDITS respected.

**A missing-signal report is a demo brief.** When the gate attribution says no
declared gate would have caught the incident, the honest next artifact is
often a runnable demo of the property that was missing — that is how
`gray-failure-demo` and `retry-storm-demo` came to exist. Record it as such in
the close-out and add it to `demos/INDEX.md`'s queue rather than leaving
"nothing would have caught this" as the last word.

**A metastable incident is reproduced by a procedure, not by a fixture.** When
the timeline shows a system that stayed down after its trigger was removed,
`references/chaos-load-framework.md` step 7 is the shape of the reproduction —
and the recovery bound it measures becomes the candidate invariant. A fixture
that replays only the collapse misses the property that made the incident
expensive.

## Bail

Preamble format. Expected `blocked_on` values: `sparse-input` (RULE
SPARSE-INPUT, with the missing-material list), `no-prefix-commit` (cannot
identify a pre-fix state to demonstrate red on — name what you tried), and
`analysis-not-final` — the request arrived while the incident was still being
debugged, which the frontmatter's DO NOT TRIGGER anticipates and the Bail
section had no value for. List the contract inputs still missing (timeline,
log/trace window, culprit commit, the fix) so the close-out can be resumed
rather than restarted; this skill consumes a finished analysis and cannot page
through a live system.

**Before any bail, establish that material is genuinely ABSENT rather than
merely un-fetched.** Dispatch `prod-scout` (per `references/dispatch.md`) to
enumerate what exists for the incident window — retention range, traces
matching the failing operation, the config versions in effect — and name that
enumeration in the bail. "I could not find it" and "it does not exist" are
different findings, and only the second is a bail.
