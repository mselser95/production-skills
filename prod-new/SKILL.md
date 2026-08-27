---
name: prod-new
description: >
  Greenfield: create a NEW service repo that is born at the standard instead of
  retrofitted to it. Scaffolds the three architectural zones (pure decision
  core / durable orchestration / shell), with tracing, metrics, an
  observability contract, injected clock+random+IDs, invariant counters, the
  replay corpus, liability registries with expiry enforcement, conformance kits
  per capability class, and every GATE wired into CI and the Makefile from the
  first commit — so the easiest code to write in the repo is already the
  compliant code. DERIVES which architectural machinery this service actually
  needs (event log, inbox, outbox, snapshots, reconciliation) from what it does
  and what it owns, so a CRUD service does not inherit a journal it will never
  replay. Derives every threshold from the org tier policy and asks ONLY the
  handful of things it cannot: what the service does, its tier, its boundaries,
  and what must never happen. Ends with the standard's own probe green on an
  empty service.
  TRIGGER when: a new service or repo is being created ("new service", "start
  a repo for X", "bootstrap a greenfield service", "scaffold a new Go service
  at the standard", "armemos el repo nuevo de X").
  DO NOT TRIGGER when: the repo already exists — that is prod-bootstrap
  (brownfield onboarding, which inventories and ratchets instead of
  scaffolding); or the ask is a task inside an existing governed repo
  (prod-spec).
---

# prod-new — a repo born at the standard

Read `references/preamble.md` first, then `references/tier-policy.yaml` (every
threshold and class checklist), `references/dimensions.md` (the completeness
list), `references/mechanism-derivation.md` (which machinery this service
actually needs) and `references/verification-probes.md` (verify the effect,
never the report). If `_shared/domain-topology.yaml` exists, also read
`references/domain-boundaries.md` before Phase 1 — it decides whether Q3
carries a domain sub-question at all.

The thesis this skill exists to serve: **retrofitting the standard costs
weeks; being born with it costs an afternoon.** Everything the brownfield path
has to negotiate — a core that already does I/O, a test suite with no
provenance, a CI that runs one lane, a manifest nobody checks — is free if it
is there from the first commit. So this skill installs the whole machine, not
a starting point to grow into it.

## Contract

- **Input:** a service name, a one-line purpose, and a present human for four
  questions. Optionally: the git owner/org and a language (default Go).
- **Output:** a repo whose FIRST commit already satisfies the standard —
  `make verify-standard` green, `make verify` green, every dimension either
  implemented or a ratified decline with its reason. Plus the PR/branch that
  proposes it, if the remote already exists.

## Decision rules

- **RULE DERIVE-FIRST:** every threshold, obligation, scenario checklist and
  gate comes from `tier-policy.yaml`. If you are about to ask for a number,
  the policy already answered it.
- **RULE FOUR-QUESTIONS:** the human is asked exactly four things, in ONE
  batched message with your proposal pre-filled for each (see Phase 1). Never
  an interrogation, never a question whose answer you can derive.
- **RULE BORN-COMPLETE:** the scaffold ships metrics, continuous profiling,
  the observability contract, invariant counters, conformance kits, the replay
  corpus, registries + expiry gate, and all lanes wired — plus tracing wherever
  RULE DERIVED-MECHANISMS says it is warranted. A dimension the service
  genuinely cannot have yet is a **ratified decline recorded in the spec**,
  never an omission.
- **RULE DERIVED-MECHANISMS:** the ARCHITECTURAL machinery — event log,
  inbox/dedup, outbox, snapshots, reconciliation, and the INBOUND half of
  distributed tracing — is not shipped unconditionally. It is DERIVED from the
  Phase-1 answers per `references/mechanism-derivation.md`, and a mechanism
  derived NOT WARRANTED is left out with its deriving property recorded in
  `out_of_scope`.

  **Tracing is the derived mechanism people get wrong in both directions.** A
  headless service — a queue consumer, a cron batch, a daemon nothing calls —
  owes no inbound trace extraction, and demanding it produces root spans
  nothing can parent. But the decline covers ONLY that half: span emission and
  EGRESS injection stay warranted, a correlation id is universal, and
  continuous profiling is never derived away at all (`mechanism-derivation.md`
  §8 and §9). Deleting the observability package because tracing was declined
  removes three mechanisms to decline one. The verdict is READ OFF the repo's
  own signals, never asked.

  **The mechanism is derived; the dimension is not.** Declining the event log
  does not decline `bounded_boot` — that question is still owed and still
  probed, just answered differently ("boot loads nothing; state lives in
  Postgres"). This is the distinction that keeps the rule honest: a CRUD
  service should not inherit a journal, a watermark and a compaction loop it
  will never run, because a scaffold that ships an event log to a CRUD service
  teaches that event logs are the standard. They are not. The standard is
  knowing whether you need one.
- **RULE EMPTY-BUT-REAL:** the scaffold's example capability, invariant,
  fixture, kit and span are REAL and exercised by the gates, not TODOs. A
  scaffold whose tests pass because they assert nothing teaches the opposite
  of the standard.
- **RULE NO-INVENTED-SEMANTICS:** capability semantics, invariants and the
  tier come from the human's answers. You may propose them from the purpose
  line; you may not decide them.

## Phase 1 — The four questions (one message, proposals pre-filled)

Everything else is derived. Ask:

1. **What does it do, and what does it own?** (one line each) — this is the
   only genuinely free-form input; it drives your proposals for the rest.
2. **Tier**, proposed from consequence: irreversible external effects +
   unreconstructable data integrity ⇒ T0; feeds a T0 consumer ⇒ T1 with the
   T0 invariant-flake rule; internal tooling ⇒ T2.
   The human may pick LOWER than your proposal. That answer is ratified and
   you do not argue it — but do not quietly shrink the build to match either.
   The tier sets the THRESHOLDS (coverage signal, which lanes gate, whether a
   flaky invariant may be quarantined); it does not cap what you implement.
   Ship the full machine, and record the over-delivery in `production.yaml`
   as a deliberate fact, so the next reader sees a T2 repo that runs fuzz and
   benchmarks on purpose rather than a repo whose tier looks mislabelled.
3. **Boundaries**, proposed as a capability list with classes from the purpose
   line: which external systems it calls, is called by, reads, consumes, or
   holds state in. Each gets a class (`external_effect`, `source_of_truth`,
   `event_consumer`, `event_producer`, `external_read`, `connection`,
   `signer`, `domain_gateway`) — and the class carries its obligations and
   scenario checklist automatically.

   **When `_shared/domain-topology.yaml` exists, this question also carries
   the domain classification — never a fifth question, the same batched
   line.** Propose `owning_domain` and `domain_role` from the purpose line
   against the topology's own entries (the human confirms or corrects, same
   as every other proposal here), and for each declared dependency that
   targets another domain, propose which capability it depends on FROM THE
   TOPOLOGY'S OWN METADATA, not from inspecting the target repo — this
   skill's input is one new service and a present human, never another
   repo's checkout. Record the proposed `via:` capability and mark it
   `UNVERIFIED-CROSS-REPO` in the spec rather than a plain pass; confirming it
   is actually classed `domain_gateway` in the target's own spec is
   `prod-review`'s job the first time this dependency's traffic is reviewed,
   never something scaffolded as already checked
   (`references/domain-boundaries.md`, "What this cannot prove locally").
   Where the topology file is absent, skip this paragraph entirely — it is a
   silent N/A, not a gap.
4. **What must never happen?** — seeded with candidates you infer from the
   purpose (conservation, at-most-once effect, no stale-as-fresh, authz
   boundaries). These become the seed invariants; they are the reason the repo
   has a `verification/ratified/` at all.
   The human ratifies a SUBSET. What they did not ratify is not discarded and
   not silently promoted: it is a CANDIDATE, and candidates have their own
   home (see "Two homes for an invariant" under Phase 2).

Two things you DERIVE and merely state (never ask): whether durable
orchestration is needed (a multi-step saga with external effects ⇒ yes; a
stateless transform ⇒ no) and the latency budget's implication (a sub-ms hot
path keeps the shell's own recovery protocol rather than routing through a
durable engine).

## Phase 1b — Derive the mechanism set (no new questions)

Run `references/mechanism-derivation.md` against the four answers. It takes the
purpose line, what the service OWNS, and the declared capability classes, and
returns per mechanism `warranted` / `not warranted` / `needs one more
question` — **each naming the property that decided it.**

This is machinery for deriving MORE from the same four answers, never a fifth
question. The single verdict that may reach the human is `needs one more
question`, and it rides inside the Phase-1 batched message rather than
becoming another round trip.

Present the verdicts WITH their properties. A verdict is a proposal: the human
may overturn any of them, and an override is recorded with THEIR reason, not
yours. If several services in a row overturn the same verdict, the property
that produced it is wrong — fix it in the reference, not with a special case
here.

Phase 2 then scaffolds the derived set, not the full one.

## Phase 2 — Scaffold (the derived machine)

Run the derivation FIRST (`references/mechanism-derivation.md`), then scaffold
the set it returns. The four Phase-1 answers are its whole input; it is not a
fifth question.

**How a partial scaffold is produced, in order.** Two agents following this
must land on the same tree, so the order is fixed and each step is checkable:

1. Copy `template/` whole and instantiate every `<slot>`. Start from the full
   tree even when the derivation trimmed it — removing from a working scaffold
   is checkable, and assembling one from parts is not.
2. For each mechanism the derivation returned `not warranted`, apply its
   removal shape — and for the event log, note that the ROLE decides what
   comes out even when the log itself stays. The derivation reference's "What removal actually costs"
   table says which of three shapes each mechanism has —
   **package + wiring**, **wiring only**, or **declaration only** — and the
   nine-item debris list says what a package-shaped removal leaves behind.
   Items 7 and 8 of that list are the ones that bite: a stale line in
   `scripts/coverage-floors.txt` fails the ratchet as if coverage had
   regressed, and the `Makefile`'s `Fuzz*` and e2e name-guards fail loudly
   for a target that is deliberately gone.
3. Record every verdict in `production.yaml` — warranted ones as capability
   entries, not-warranted ones under `out_of_scope` with the DERIVING
   PROPERTY as the reason, never a bare "not needed".
4. Run `make verify-standard`. A correctly trimmed scaffold reaches FAIL 0
   through NA rows, because the probe reads those declines. If a row FAILs
   instead of going NA, the decline is missing or misspelled — fix the spec,
   never the probe.

**How a reviewer tells whether this was followed.** Three checks, none of
which requires re-deriving anything: every `out_of_scope` entry names a
property rather than a preference; no absent mechanism is still named in
`coverage-floors.txt` or the `Makefile` guards; and the probe's report shows
NA where the spec declines rather than a shorter report with rows missing.

**When the derivation and the template disagree, say so and stop.** The
template's example domain is a fold (`Apply(state, event)`) and its app layer
journals before applying — so the event log is not a package the example uses,
it is the example's shape across three layers. A service the derivation says
is not event-sourced therefore cannot be scaffolded by omission today: you
would produce a broken event-sourced skeleton, not a CRUD one. The derivation
reference states this blocker and its scope. Tell the human plainly rather
than shipping a broken tree or silently shipping the full one.

What ships, for the mechanisms that survive derivation:

**Zones** — `internal/domain` (pure: no I/O, no clock, no random, no
goroutines), `internal/app` (orchestration over ports; state transitions with
their recovery semantics), `internal/adapter/{in,out}` + `internal/platform`
(shell), `cmd/<service>` (composition root only).

**Determinism** — clock, randomness and ID generation are injected ports with
real implementations at the composition root and deterministic fakes in tests;
`Output = F(code, config, state, inputs)` with all four versioned and surfaced
(build revision + config digest in a `build_info` metric, the health body, and
as base attributes on every span).

**Event sourcing / replay** — with `Apply(state, event) -> (state, effects)`
in the core; and, ALWAYS, the `regressions/` replay corpus harness that drives
fixtures through the real decode→core→serve path asserting invariants at every
transition.

Do not assume the event LOG applies, and do not treat it as a yes/no — §1 of
`references/mechanism-derivation.md` returns a ROLE: `produce`, `consume`,
`both`, or `none`. Durable state is not the test (a CRUD service has durable
state and wants no event log), and neither is "event sourced" on its own: the
role decides which machinery ships. A consumer gets a cursor and a gap guard
and NO optimistic concurrency, because it never assigns a sequence and so has
nothing to conflict with; a producer gets the version check and no gap guard,
because it cannot receive a hole in a sequence it assigns itself. Scaffolding
one role's machinery for the other yields a guard that can never fire, which
is the hardest kind of dead code to notice.

`both` is the ordinary case, not an exotic one — this template's own
downstream service ingests an upstream feed and originates trades. When the
role is `both`, §1's one-log-or-two question goes into the Phase-1 batched
message and its answer into the spec. When it does not apply, that is a RATIFIED DECLINE with its
deriving property in the spec's `out_of_scope`, never a silence.

The mechanisms that travel WITH the log are derived from it and recorded the
same way: snapshots + compaction (§4) exist to bound a replay, so no log means
nothing to snapshot; and the outbox's durability STRATEGY (§3) changes shape
entirely — with a log the outbox can be a projection plus a delivery watermark,
without one the outbox record is the only evidence the intent ever existed and
must be atomic with the state change it accompanies.

**The corpus is not derived — only the log is.** `regressions/` stays required
either way: it is fixtures driven through the real path asserting invariants,
which is valuable whether or not those fixtures came from a durable log. A
repo that declines event sourcing still owes its regression corpus, and the
probe must not let one excuse the other.

**Effects** — the outbox, WHEN derived (§3: warranted only if this service
causes effects outside itself that must not be lost; a service whose every
capability is `source_of_truth` or `external_read` writes nowhere a crash could
lose it, and "we write to our own database" is not an external effect). Where
it applies: intent is journaled before any external effect, and the recovery
function is table-driven over the full "journal says X, world says Y" matrix.
The idempotency key is minted per ENTRY and persisted with it — not per
`Publish` invocation, or every recovery pass presents a fresh key and defeats
the deduplication the key exists for.

**Observability** — a tracing port with a no-op default plus a structured-log
adapter (no library dependency), spans on every declared critical transition,
a metrics manifest, a spans manifest, and the contract test that scrapes the
real endpoint and fails on drift in BOTH directions. One counter per ratified
invariant, each asserted to stay 0 and asserted to increment under a
deliberately violating call so it is never dead code.

**Four signals, not three.** Profiles are the fourth, and they are the one the
scaffold ships only half of: `pprofhttp` plus `benchmarks/profile.sh` is the
ON-DEMAND half — someone taking a profile while the incident is still live.
`dimensions.md` §8 requires the CONTINUOUS half too, in every service headless
or not, because the profile that explains a regression is the one that was
already being taken when it happened. That half lives in the deployment (an
always-on sampling profiler shipping to a store with retention), so the
scaffold cannot ship it and must not imply it did: say what the template gives
(on-demand) and what the service owner still owes (continuous collection, with
the build identity attached so profiles are comparable across a deploy). The
inbound half of tracing, by contrast, is derived — see RULE
DERIVED-MECHANISMS.

**Verification** — `verification/ratified/` (seed invariants as executable
tests, each with its non-vacuity mutation recorded), `verification/conformance/`
(a kit per declared capability class, wired to every adapter),
property/metamorphic tests over the core, a fuzz target per decode boundary
with a seed corpus, and the `.prod/ratify-queue/` packages behind each
invariant.

**Two homes for an invariant, and they are not interchangeable.** The probe
treats every file in `.prod/ratify-queue/` as backing a RATIFIED invariant: it
applies that package's `non_vacuity_check` and runs `expect_red` SCOPED TO
`verification/ratified/`. So a package whose evidence is a property test in
`internal/domain` cannot live there — the scoped run finds no such test,
prints `ok [no tests to run]`, and the probe classifies that as
STAYED-GREEN, i.e. a vacuous invariant, i.e. a FAIL. Therefore:

- **Ratified** ⇒ an executable test in `verification/ratified/`, a package in
  `.prod/ratify-queue/` carrying a real `non_vacuity_check` (file /
  expect_red / find / replace), and an entry under `invariants:` in
  `production.yaml`. The mutation must make the TEST fail, not the BUILD —
  the probe reads a compile break as a decayed mutation, not a detection.
- **Candidate** ⇒ an entry under `invariants_pending_ratification:` in
  `production.yaml` (the probe already reads that key and reports its count
  separately), with its evidence package anywhere that is NOT the
  ratify-queue — `.prod/candidates/` with a README explaining the split works
  well. Exercise it continuously as a property; it gates nothing until a
  human ratifies it, at which point the test moves into the trusted set and
  the package moves into the queue.

Writing a candidate into the ratify-queue to "keep them together" turns a
green probe red for a reason nobody will diagnose. Writing an unratified test
into `verification/ratified/` is worse: it launders scaffold-time authorship
into ratification, which is the one thing the human gate exists to prevent.

**If the harness write-masks `verification/ratified/`, that is expected.** The
preamble puts the trusted set out of reach of every prod-* skill, and this
skill is the exception that CREATES it — a greenfield repo has no invariants
until Phase 2 writes them. If a write is refused there, do not route around it
silently: say plainly which file you are creating and why this skill is
allowed to, or bail. Creating the seed invariants is in-contract; editing an
existing repo's ratified set never is.

**Gates and lanes** — `make check-fast` (seconds), `make verify` (the full
lane), `make test-advisory` (candidate build tag), `make bench`,
`make verify-standard` (the standard's own probe), `make check-registries`
(expiry gates the build); CI wires them as staged jobs with a nightly trend
lane for mutation, extended fuzz and soak. Coverage carries a per-package
ratchet plus changed-line coverage as a signal.

**Governance** — `production.yaml` (semantics only, `verified:`/`assumed:`
split per capability, ratified declines, no invented escape keys — plus
`service.owning_domain`/`service.domain_role`/`domain_dependencies` ONLY when
Phase 1's Q3 carried the domain sub-question), `AGENTS.md` from
`references/agents-template.md` (its `<IF DOMAIN-AWARE>` lines instantiated
under the same condition), `CODEOWNERS` with a real owner,
`registries/{flags,waivers,quarantine,contract-debt}.yaml` plus
`registries/domain-boundaries.yaml` when domain-aware, `docs/RUNBOOK.md`,
`docs/SLO.md` (objectives marked proposed), `observability/alerts.md`, and the
`.prod/evidence/` record the probe writes per commit.

## Phase 3 — Prove it, then hand it over

1. Run `make verify` and `make verify-standard`. **The standard's own probe
   must report zero FAIL on the empty service.** A scaffold that ships red
   teaches that red is normal. This includes MINTING the load baseline: the
   template ships `benchmarks/load/` (the generator) plus only
   `baseline-TEMPLATE.md`, and the probe's `load-baseline` row engages the
   moment that directory exists — so run `make load` once against the
   scaffolded service to produce `benchmarks/load/baseline.md` measured on
   the machine that will run it. A capacity number invented at scaffold time
   is the one artifact people quote in a design review; a measured one from
   an empty service is a real lower bound the first feature updates.
2. Verify non-vacuity of what you shipped: each seed invariant observed RED
   under its recorded mutation, each fuzz target executed, the replay fixture
   red on a deliberately broken variant. Record the evidence where the
   artifact lives.
3. **RUN every gate script you authored, then break what it guards and watch
   it go red.** Phase 2 ships a whole `scripts/` directory, and a shell gate
   is the easiest thing in this repo to ship broken: `bash -n` parses it and
   executes nothing, so a script that dies on its first line still "passes
   validation" and then prints a confident wrong verdict. Execute it, read
   its output, and confirm it FAILS when it should — including when its input
   set is empty (see preamble §4b). An unrun gate is an ungated dimension.
4. Emit the first `.prod/evidence/<sha>.json`. Delete any evidence record the
   template shipped: a record naming another commit, produced by an older
   probe with different row names, is a green attestation for a state this
   repo was never in.
5. Report: the four answers as ratified, **the mechanism derivation — every
   verdict with the property that produced it, including the NOT-WARRANTED
   ones** — what was declined and why, what was ratified vs left CANDIDATE, the
   probe table, and the ONE command the next engineer runs to add their first
   feature (`prod-spec`). Where domain-aware: `owning_domain`/`domain_role`
   as ratified, and every `domain_dependencies` entry with the gateway it
   resolves through (or the UNVERIFIED-CROSS-REPO flag if it couldn't be
   confirmed). Nothing else should be left for the human to remember.

   Report the not-warranted verdicts as prominently as the warranted ones. A
   reader who finds no outbox six months from now will otherwise assume it was
   forgotten, and either add one nothing needs or distrust the whole scaffold.

## Guardrails

- Preamble in full. Greenfield-specific:
  - **Never ship a TODO where a mechanism belongs.** An empty registry is
    fine (it has no entries yet); an empty *checker* is not.
  - **Never ship a passing test that asserts nothing** — that is the
    coverage theater the standard exists to prevent, installed as a habit.
  - The scaffold's own `verification/**` is trusted-set: the repo is created
    with CODEOWNERS and deny-rule guidance covering it from commit one.
  - If the human is absent, BAIL: tier, boundaries and invariants are
    semantic and are never guessed.

## Bail

Preamble format. Expected `blocked_on`: `headless` (no human for the four
questions), `repo-exists` (use prod-bootstrap), `language-unsupported` (the
template is Go today — say so rather than improvising a half-scaffold).

**`chmod u+w` everything copied out of the installed skill directory.** The
installed TCB is left read-only by `install.sh` (so an incidental write to a
trusted file fails loudly instead of silently), and `cp` preserves mode — so a
template copied into the target repo arrives read-only and the first edit that
fills its slots dies with EACCES. Copy, make writable, then fill. This is not
hypothetical: it broke the first bootstrap run after read-only landed.
