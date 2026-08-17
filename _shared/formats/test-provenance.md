# Format: test provenance

Every test authored by an agent carries a machine-readable header. The verifier
counts only `ratified` and `derived` assertions toward gates and mutation
credit; `candidate` tests run in the advisory lane and expire.

## Header (comment block immediately above the test function — Go shown as
## the example; adapt the comment syntax to the repo's language)

```go
// provenance: ratified|derived|candidate
// verifies: <invariant-id | capability-id/clause | ->  ("-" only for candidate)
// author: <skill-name>@<date>
// ttl: <date>            // candidate only, mandatory, max 30 days
func TestLedgerConservation_RandomEventSequences(t *testing.T) { ... }
```

## Classes

- **ratified** — asserts a human-approved invariant. `verifies:` must name an
  invariant id that resolves to a symbol under `verification/ratified/`.
  Agents never author these; a test becomes `ratified` only when the invariant
  it asserts passes the invariant ratification queue. (Test promotion via
  `prod-curate` produces `derived`, not `ratified`.)
- **derived** — generated mechanically from a capability contract clause
  (e.g. `ambiguous_outcome: possible` ⇒ the retry-idempotency conformance
  case). `verifies:` names the clause. Derivation must be reproducible.
- **candidate** — agent-authored, oracle unverified. Runs, never blocks,
  expires at `ttl` unless promoted. A candidate asserting exact values not
  derivable from any ratified property is a **pinning test** and must say so:

```go
// provenance: candidate
// verifies: -
// pinning: true          // change-detector by construction; promotion requires
                          // rewriting against a ratified property
```

## Lanes

The lane is mechanical, not aspirational — a candidate test is segregated by
BOTH markers so no tool needs to parse headers to exclude it (Go example;
adapt per language):

- file suffix `_candidate_test.go`, and
- build tag `//go:build candidate` (the blocking CI job builds without the
  tag; the advisory job builds with it).

- Blocking lane: `ratified` + `derived` only. Lives with the code.
- Advisory lane: `candidate`. CI runs it non-blocking, reports results,
  deletes tests past TTL (deletion by TTL expiry is the ONE test deletion that
  needs no human review — it was never load-bearing).

## Promotion (prod-curate, in batches, never one-off)

A candidate is promotable when it survives ALL of:
0. Eligibility: ≥ the configured minimum advisory-lane runs with a stable
   record, inside its TTL, and without `pinning: true`.
1. Change-detector screening: passes on every commit in the refactor corpus
   (known behavior-preserving commits).
2. Mutant utility: kills ≥1 mutant not already killed by the blocking lane.
3. Kata check: fails on the known-bad implementations for its capability.
4. Sampled human review at the batch level.
