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
2b. **Error branches are a first-class target, not a leftover.** Yuan et al.,
   "Simple Testing Can Prevent Most Critical Failures" (OSDI 2014), found
   that 92% of catastrophic failures in the distributed systems they studied
   followed the incorrect handling of an error the software had already
   signalled. That measurement makes error paths the highest-empirical-value
   surface this skill can emit tests for, and they are enumerable in exactly
   the sense step 2 means: list every error return of the unit under test,
   emit a candidate that DRIVES each one (the injected failure reaches that
   specific return, not merely some error), and assert the obligation the
   framework already states for a failure branch — a distinguishable signal,
   not just a non-nil error. Two branches returning the same opaque value are
   one branch as far as production is concerned, so a test asserting only
   "an error came back" is the vacuous form here; it passes on the day the
   two paths are silently merged. Error returns you could not reach go in
   `uncovered` with the reason — an unenumerated error path is
   indistinguishable in this report from one that does not exist.
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
4b. **Metamorphic comparison over STRUCTURED output goes through a declared
   canonicalization.** Naive deep equality across a metamorphic pair compares
   fields sourced from the injected clock, the random port and the ID
   generator, so it fails for reasons that have nothing to do with the
   relation under test — and the fix people reach for is loosening the
   assertion until it passes. Name the canonicalization function in the test,
   and exclude port-sourced fields explicitly rather than by omission.
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

**Demos are oracle sources, not just illustrations.** Where `demos/INDEX.md`
has made a property executable, its assertions are a legitimate oracle to
generate against — they are derived from a cited source and were proven to
fail under mutation, which is more than most contract clauses can say.

## Guardrails

- Preamble §6 is absolute: no header, no test. No candidate ever placed in a
  blocking path, a `verification/ratified/` dir, or cited as `ratified`.
- You never edit existing tests, generators, or fixtures — additive only.
- **Pinning is the per-test fallback, not a mode.** If more than ~30% of a
  batch comes out `pinning: true`, stop and report it: the target's contract
  surface is too thin to synthesize against, and a batch of pinning tests is a
  change-detector farm that curation will discard wholesale after paying to
  screen it.
- **"Would survive a refactor" needs an operational test, or it is a wish.**
  An assertion is admissible only if it references the unit's EXPORTED surface
  or a declared observable effect — a returned value, a typed error, an
  invariant counter or metric, persisted state, an emitted event. An assertion
  over call order, private helpers, or the number of times a collaborator was
  invoked is a change detector by construction, whatever it is named.
- Do not chase kill-counts: a candidate that exists to kill one mutant via a
  call-sequence assertion will be discarded by curation's screening anyway.
  Write assertions that would survive a refactor.

## Bail

Preamble format. Mandatory bail: the TARGET AS A WHOLE has no contract clauses
and no ratified invariants to cite → nothing here can be verified, only pinned;
report that as the finding (the gap is upstream, in the spec).

A bail still emits BOTH artifacts: the preamble BAIL block AND a SYNTHESIZED
report with `counts: 0 / 0 / 0`, `adequacy: n/a`, and every requested clause or
checklist entry listed under `uncovered` with its reason. A bail that omits the
report leaves no record of WHAT was not synthesized, which is the half the next
run needs.
