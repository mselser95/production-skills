---
name: prod-test-synth
description: >
  Implementer skill (cheap-model tier): generate CANDIDATE-lane tests, property
  generators, and scenario cases from capability contract clauses and code
  under test — with mandatory provenance headers and TTLs, generator adequacy
  self-checks (state diversity, precondition rejection ceiling), and zero
  ability to touch the blocking lane. Volume is welcome here precisely because
  candidates cannot contaminate truth: promotion is prod-curate's job, behind
  screening and human sampling.
  TRIGGER when: test volume is wanted over a contract surface ("synthesize
  candidates for the broadcaster capability", "generate property cases for the
  settlement core", the coverage-expansion step of a prod-* pipeline).
  DO NOT TRIGGER when: the tests must block CI now (that requires ratified or
  derived provenance — write them via prod-implement citing real clauses, or
  promote via prod-curate), or the ask is to fix/delete existing tests (human
  review, always).
---

# prod-test-synth — candidates at volume, truth untouched

This skill is normally EXECUTED BY the `prod-implementer` agent (cheap tier —
see `references/dispatch.md`); batch fan-outs over many clauses go one agent
per clause-group.

Read `references/preamble.md` first. Every test follows
`references/test-provenance.md` — that spec is this skill's contract.

## Contract

- **Input:** a target — a capability (its contract clauses), a core package
  (its ratified invariants as properties to generate against), or a scenario
  checklist entry — plus the repo.
- **Output:** test files in the ADVISORY lane only, each function carrying a
  full provenance header (`candidate`, `ttl`, `verifies:` citation or
  `pinning: true`), plus a synthesis report (below).

## Algorithm

1. **Read the clause, not the vibe.** Each generated test cites what it
   verifies: a capability contract clause (⇒ it is a `derived` CANDIDATE for
   promotion — still lands as `candidate`; the derived classification is
   claimed at promotion when the derivation is shown reproducible) or a
   ratified invariant id. A test you cannot attach to either is a pinning
   test and must be marked `pinning: true`.
2. **Table-driven by default.** For enumerable spaces (the class checklists:
   timeout-after-accept, duplicate delivery, journal-says-X world-says-Y),
   enumerate — do not sample what can be enumerated.
3. **Property tests get adequacy self-checks, generated with them:**
   - state diversity: the generator's observed-state count over N runs is
     asserted above a floor (a generator producing only well-formed balanced
     inputs fails its own test);
   - precondition rejection: the share of discarded cases is asserted below a
     ceiling (tightening `Assume()` until the property passes is the classic
     vacuous-generator move — make it structurally visible).
4. **No exact-value oracles from the implementation.** Reading the current
   output and asserting it is change-detection, not verification. Allowed
   oracles: ratified properties, contract clauses, metamorphic relations
   (repeat-op no double effect; identity is neutral; adding protection never
   worsens the protected metric), and enumerated failure-mode outcomes.
5. **TTL on everything.** `ttl:` at most `PROD_CANDIDATE_TTL_DAYS` (default
   30). Expiry deletes without ceremony; promotion is `prod-curate`'s batch.
6. **Synthesis report:**

```
SYNTHESIZED
target: <capability/package/scenario>
files: <paths>
counts: <n clause-cited / n invariant-cited / n pinning>
adequacy: <generator checks embedded: yes/no per generator>
uncovered: <clauses or checklist entries you could NOT synthesize for, and why>
```

`uncovered` is the honest line — silence there reads as full coverage.

## Guardrails

- Preamble §6 is absolute: no header, no test. No candidate ever placed in a
  blocking path, a `verification/ratified/` dir, or cited as `ratified`.
- You never edit existing tests, generators, or fixtures — additive only.
- Do not chase kill-counts: a candidate that exists to kill one mutant via a
  call-sequence assertion will be discarded by curation's screening anyway.
  Write assertions that would survive a refactor.

## Bail

Preamble format. Mandatory bail: the target has no contract clauses and no
ratified invariants to cite → nothing here can be verified, only pinned;
report that as the finding (the gap is upstream, in the spec).
