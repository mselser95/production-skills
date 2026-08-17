---
name: prod-new
description: >
  Greenfield: create a NEW service repo that is born at the standard instead of
  retrofitted to it. Scaffolds the three architectural zones (pure decision
  core / durable orchestration / shell), with tracing, metrics, an
  observability contract, event-sourced replay, injected clock+random+IDs, the
  outbox pattern on external effects, invariant counters, liability registries
  with expiry enforcement, conformance kits per capability class, and every
  GATE wired into CI and the Makefile from the first commit — so the easiest
  code to write in the repo is already the compliant code. Derives every
  threshold from the org tier policy and asks ONLY the handful of things it
  cannot: what the service does, its tier, its boundaries, and what must never
  happen. Ends with the standard's own probe green on an empty service.
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
list) and `references/verification-probes.md` (verify the effect, never the
report).

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
- **RULE BORN-COMPLETE:** the scaffold ships tracing, metrics, the
  observability contract, replay/event-sourcing, invariant counters, the
  outbox, conformance kits, registries + expiry gate, and all lanes wired. A
  dimension the service genuinely cannot have yet (no durable state ⇒ no
  reconciliation) is a **ratified decline recorded in the spec**, never an
  omission.
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
3. **Boundaries**, proposed as a capability list with classes from the purpose
   line: which external systems it calls, is called by, reads, consumes, or
   holds state in. Each gets a class (`external_effect`, `source_of_truth`,
   `event_consumer`, `event_producer`, `external_read`, `connection`,
   `signer`) — and the class carries its obligations and scenario checklist
   automatically.
4. **What must never happen?** — seeded with candidates you infer from the
   purpose (conservation, at-most-once effect, no stale-as-fresh, authz
   boundaries). These become the seed invariants; they are the reason the repo
   has a `verification/ratified/` at all.

Two things you DERIVE and merely state (never ask): whether durable
orchestration is needed (a multi-step saga with external effects ⇒ yes; a
stateless transform ⇒ no) and the latency budget's implication (a sub-ms hot
path keeps the shell's own recovery protocol rather than routing through a
durable engine).

## Phase 2 — Scaffold (the whole machine)

Copy `template/` and instantiate every `<slot>` from the answers. What ships:

**Zones** — `internal/domain` (pure: no I/O, no clock, no random, no
goroutines), `internal/app` (orchestration over ports; state transitions with
their recovery semantics), `internal/adapter/{in,out}` + `internal/platform`
(shell), `cmd/<service>` (composition root only).

**Determinism** — clock, randomness and ID generation are injected ports with
real implementations at the composition root and deterministic fakes in tests;
`Output = F(code, config, state, inputs)` with all four versioned and surfaced
(build revision + config digest in a `build_info` metric, the health body, and
as base attributes on every span).

**Event sourcing / replay** — an append-only event log for the owned
aggregates when the human declares durable state, with `Apply(state, event) ->
(state, effects)` in the core; and, always, the `regressions/` replay corpus
harness that drives fixtures through the real decode→core→serve path asserting
invariants at every transition. If there is no durable state, the log is a
ratified decline and the corpus remains.

**Effects** — the outbox: intent is journaled before any external effect, and
the recovery function is table-driven over the full "journal says X, world
says Y" matrix. Idempotency keys are generated INSIDE the retry closure.

**Observability** — a tracing port with a no-op default plus a structured-log
adapter (no library dependency), spans on every declared critical transition,
a metrics manifest, a spans manifest, and the contract test that scrapes the
real endpoint and fails on drift in BOTH directions. One counter per ratified
invariant, each asserted to stay 0 and asserted to increment under a
deliberately violating call so it is never dead code.

**Verification** — `verification/ratified/` (seed invariants as executable
tests, each with its non-vacuity mutation recorded), `verification/conformance/`
(a kit per declared capability class, wired to every adapter),
property/metamorphic tests over the core, a fuzz target per decode boundary
with a seed corpus, and the `.prod/ratify-queue/` packages behind each
invariant.

**Gates and lanes** — `make check-fast` (seconds), `make verify` (the full
lane), `make test-advisory` (candidate build tag), `make bench`,
`make verify-standard` (the standard's own probe), `make check-registries`
(expiry gates the build); CI wires them as staged jobs with a nightly trend
lane for mutation, extended fuzz and soak. Coverage carries a per-package
ratchet plus changed-line coverage as a signal.

**Governance** — `production.yaml` (semantics only, `verified:`/`assumed:`
split per capability, ratified declines, no invented escape keys), `AGENTS.md`
from `references/agents-template.md`, `CODEOWNERS` with a real owner,
`registries/{flags,waivers,quarantine,contract-debt}.yaml`, `docs/RUNBOOK.md`,
`docs/SLO.md` (objectives marked proposed), `observability/alerts.md`, and the
`.prod/evidence/` record the probe writes per commit.

## Phase 3 — Prove it, then hand it over

1. Run `make verify` and `make verify-standard`. **The standard's own probe
   must report zero FAIL on the empty service.** A scaffold that ships red
   teaches that red is normal.
2. Verify non-vacuity of what you shipped: each seed invariant observed RED
   under its recorded mutation, each fuzz target executed, the replay fixture
   red on a deliberately broken variant. Record the evidence where the
   artifact lives.
3. Emit the first `.prod/evidence/<sha>.json`.
4. Report: the four answers as ratified, what was declined and why, the probe
   table, and the ONE command the next engineer runs to add their first
   feature (`prod-spec`). Nothing else should be left for the human to
   remember.

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
