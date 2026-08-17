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
`references/incident-fixture.md` — all four artifacts, every time. An incident
close-out that produces only a fix is a discarded lesson.

## Contract

- **Input:** the incident's analysis material — timeline, logs/traces,
  the culprit change if known, the fix if merged — plus the affected repo(s).
- **Output:** under `regressions/<yyyy-mm-dd>-<slug>/` in the affected repo:
  `fixture.yaml`, `events.json`, `invariants.txt`; plus the candidate
  invariant package and missing-signal report as a ratification proposal
  (NOT committed into `verification/ratified/` — that is the human's merge).

## Algorithm

1. **Reproduce minimally.** From the incident material, construct the shortest
   event sequence that exhibits the failure against the current code with the
   fix reverted (or the pre-fix commit). Target 10–50 events. Minimization is
   the deliverable — a raw capture is fixture rot on a timer.
   If the failure cannot be reproduced in the core (it lived in the shell's
   interleavings), model the shell's part as explicit events (effect-result
   events, timeout events) — if THAT is impossible, record it honestly in
   `gate_attribution`: the simulability gap is itself the finding.
2. **Assert invariants, not snapshots.** `invariants.txt` names which ratified
   invariants must hold at every transition of the replay. If the incident
   violated something no ratified invariant captures — that IS the candidate
   invariant.
3. **Build the candidate invariant package** with evidence in both directions:
   N passing runs on fixed code AND the concrete violating trace (the fixture
   itself usually is it). Run the contradiction-check against the declared
   capability contracts: a candidate that contradicts a declared clause
   (e.g. "exactly once" vs `may_be_duplicate: true`) is wrong or the contract
   is — flag the conflict, propose nothing that contradicts silently.
4. **Missing-signal report.** For each behavior in the incident that was
   invisible or ambiguous in production telemetry: what it looked like, what
   signal would have distinguished it, the proposed metric/attribute/event.
5. **Gate attribution.** One honest paragraph: which declared gate would have
   caught this before production — or none, and why. This line is the
   framework's accounting; write it even when (especially when) the answer is
   embarrassing.
6. **Wire the fixture into CI** (advisory first): the replay runs green on
   current code. Confirm it runs red on the pre-fix commit — a fixture that
   never turned red proves nothing.

## Guardrails

- Preamble applies; §3 especially — the candidate invariant and any new
  conformance material are PROPOSALS. You never write into
  `verification/ratified/`.
- No fixture without both colors: green on fixed code, red on broken code,
  both demonstrated in the close-out.
- Do not classify the incident "irreproducible" to escape the work — if it is
  truly irreproducible, the missing-signal report and the simulability-gap
  line are the mandatory outputs instead.

## Bail

Preamble format. Mandatory bail: analysis material is insufficient to
reproduce AND to identify missing signals → list exactly what is missing
(which log window, which trace, which config version).
