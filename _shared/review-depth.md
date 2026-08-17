# Review depth — the shared audit engine

The finding-production discipline `prod-review` applies on top of its
contract phases. Distilled from a hardened senior-review methodology; two
inputs come from `config.sh` and outrank anything generic here:

- **`PROD_BLOCKER_CALIBRATION`** — the blocker bar for this domain. Wherever
  this file says "meets the blocker bar", it means that text.
- **`PROD_DOMAIN_CONTEXT`** — one line on what the product does, so findings
  reason about impact, not just mechanics.

A third input is discovered per repo, never configured: the repo's own idioms
(below).

## Hard rules — these override any contrary instinct

1. **Default to findings, not approval.** Baseline assumption: the change has
   problems. A clean verdict requires positive evidence that every area was
   checked and passed. Absence of findings is evidence you didn't look.
2. **Silence is not OK.** Every review area is assumed touched unless you
   explicitly rule it out. An unverified area goes under `NOT VALIDATED` with
   the reason — never silently omitted.
3. **No assumptions, no inventions.** A claim in the plan, a comment, or a
   test name that the code you actually read cannot back is not verified.
4. **Read full files, not diff hunks.** Diff-only reviews miss pattern
   contradictions with nearby untouched code, dead branches, and stale
   comments. Read every changed file in full.
5. **Cite file and line for every finding.** No citation ⇒ not a finding.
6. **Meets the blocker bar ⇒ BLOCKER**, regardless of how small the diff
   looks. Conversely: a fix that looks right but has no covering test is
   `MISSING TESTS`, not `BLOCKER` — don't conflate untested with broken.
7. **Never inflate to be safe.** Genuinely unsure whether something crosses
   the bar → `WARNING` with the uncertainty stated, or `NOT VALIDATED` if you
   couldn't check. A false blocker teaches the team to ignore your blockers.
8. **Prioritise findings; skip the praise.** No preamble, no "overall looks
   good".

## Repo idiom layer — apply before any style/pattern finding survives

The costliest failure mode of an automated reviewer is flagging deliberate
house style as a defect. Before a style finding survives, check it against:
the repo's own agent/contributor docs; its linter config (**an enabled rule
is CI's finding, not yours; a deliberately disabled one is an opt-out you
don't re-litigate**); and the dominant pattern in surrounding untouched code.
A pattern used consistently across the repo IS the standard, even against
community advice. Deviating from a documented house pattern IS a finding —
cite what you measured against. No conventions found → say so under `NOT
VALIDATED` and judge on general merit. Correctness always outranks idiom.

## Severity buckets

| Bucket | When |
|---|---|
| **BLOCKER** | meets `PROD_BLOCKER_CALIBRATION` |
| **WARNING** | real but bounded: smell, house-pattern deviation, perf nit |
| **MISSING TESTS** | new code/branch/endpoint with no test — always survives on NEW code, never challenged away; only pre-existing adjacent debt is exempt |
| **NOT VALIDATED** | an area you could not verify, with the reason |

The calibration split is *impact*, not diff size and not confidence. The
canonical blocker shape: silent, and the damage persists (a reused
idempotency key on retry; a precision mismatch across a serialization
boundary; state left held on an error path).

## Review areas — check every one; unverified ⇒ NOT VALIDATED

1. **Architecture & boundaries** — logic in the domain layer, not handlers or
   adapters; dependencies point the right way; judged against the repo's OWN
   layering (in this framework: the three zones — core stays pure).
2. **Logic & bugs** — inverted conditions, dangerous defaults, broken
   idempotency, races (check-then-act, captured loop vars), incorrect
   rounding/precision (a writer/reader precision mismatch is the classic
   silent-corruption blocker), retry safety: anything that must be unique
   per attempt but is generated outside the retry closure.
3. **Data & persistence** — parameterized queries (string-concatenated query
   with external input = BLOCKER), N+1, transaction scope, identifier
   confusion (display value where an internal key belongs — it type-checks
   and reads the wrong row), migrations as one-way doors (blocking ALTER on a
   hot table = BLOCKER; expand/contract discipline per the framework).
4. **Error handling** — no swallowed errors, no log-and-return-nil; wrapped
   with context; retryable-vs-terminal classified; does the error path clean
   up state (locks, reservations, partial writes)? Held-on-error meets the
   bar.
5. **Observability** — correlation ids the system actually debugs by;
   bounded-cardinality labels; the 3am question: if this fails silently in
   production, what fires? Nothing ⇒ finding. (In this framework: every new
   failure branch needs a distinguishable signal.)
6. **Performance** — hot-path allocations, calls inside held locks,
   batch-vs-row, missing timeouts, complexity changes (O(1)→O(n) fanouts).
7. **Cross-boundary contracts** — any change crossing a service boundary
   (API fields, message shapes, mirrored/generated types, queue payloads):
   verify the counterpart actually exists AT ITS SOURCE, types match
   (nullable-producer/non-nullable-consumer = BLOCKER), enums line up by
   value. Counterpart missing or unlocatable ⇒ BLOCKER or NOT VALIDATED —
   never assume the contract holds because the code compiles.
8. **Tests** — beyond existence: does the test actually test anything? A
   test asserting a mock was called, or re-asserting the implementation's own
   arithmetic, is coverage theater — call it out even when the number is
   fine. Bug fix ⇒ demand the test that fails without the fix. Fixtures
   updated for new fields.
9. **Completeness** — a field added to a type: used everywhere the type
   appears? A pattern changed in one place: left unchanged elsewhere?
   Half-applied refactors are worse than either endpoint. Does the change do
   materially more than its description claims? That is a finding in itself.
10. **Docs left stale** — a comment now describing old behavior will mislead
    the next reader; flag it.
