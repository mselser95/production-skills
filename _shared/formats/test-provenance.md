# Format: test provenance

Every test authored by an agent carries a machine-readable header. The verifier
counts only `ratified` and `derived` assertions toward gates and mutation
credit; `candidate` tests run in the advisory lane and expire.

## Header (Go comment block immediately above the test function)

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
  Agents never author these directly; they exist when `prod-curate`'s
  promotion lands with human approval.
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

- Blocking lane: `ratified` + `derived` only. Lives with the code.
- Advisory lane: `candidate`. CI runs it non-blocking, reports results,
  deletes tests past TTL (deletion by TTL expiry is the ONE test deletion that
  needs no human review — it was never load-bearing).

## Promotion (prod-curate, in batches, never one-off)

A candidate is promotable when it survives ALL of:
1. Change-detector screening: passes on every commit in the refactor corpus
   (known behavior-preserving commits).
2. Mutant utility: kills ≥1 mutant not already killed by the blocking lane.
3. Kata check: fails on the known-bad implementations for its capability.
4. Sampled human review at the batch level.
