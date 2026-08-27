# Domain boundaries — DOMA, one level above what this framework verifies

## Why this exists

Everything else in this repo is scoped to ONE repo. `production.yaml` describes
one service; `capability_classes` describe boundaries *inside* it (a DB, a
queue, an outbound client); `dimensions.md` §14 and §21 cover what that one
service publishes and who reads it. None of that asks the question a
multi-service org eventually has to answer: **which service is allowed to
depend on which, and through what door.**

That is Domain-Oriented Microservice Architecture (DOMA) — Uber Engineering's
name for classifying services by the business domain they own (`foundational`
= owns primitive data nothing else may read directly; `derived`/`aggregate` =
composes across foundational domains) and requiring every cross-domain call to
go through that domain's own published **gateway**, never its datastore. This
file is the framework's local half of that: what a single repo declares about
its own domain membership, and the one invariant every other skill in this
suite enforces once it does. It does NOT attempt to verify the global
topology — see "What this cannot prove locally" below.

## Opt-in, not required

**Everything in this file applies only when `_shared/domain-topology.yaml`
exists.** A single-service org, or an org that has not adopted a multi-domain
topology, pays nothing: every skill's DOMA-aware step is conditioned on that
file's presence, and its absence is a normal, silent N/A — never a gap-report
row, never a blocked question. Do not ask a human "what domain does this
belong to?" when there is no topology for the answer to resolve against; that
is exactly the invented-fifth-question failure `prod-new`'s RULE FOUR-QUESTIONS
exists to prevent.

`domain-topology.yaml` is org-specific data, not framework policy — unlike
`tier-policy.yaml` (a single generic source this whole repo ships), a domain
map is unique to each company's business and must never be committed here.
Copy `_shared/domain-topology.example.yaml` to `_shared/domain-topology.yaml`
(gitignored, same pattern as every skill's `config.sh`) and edit it once per
org.

```yaml
# _shared/domain-topology.yaml (org-specific, gitignored — copy from the
# .example.yaml beside it)
domains:
  payments:
    role: foundational
    owner: payments-team
    repos: [payments-ledger, payments-gateway-svc]
  identity:
    role: foundational
    owner: identity-team
    repos: [identity-core]
  checkout:
    role: derived              # composes payments + identity + catalog
    owner: checkout-team
    repos: [checkout-svc]
```

## Vocabulary

Two new `production.yaml` fields, both optional and both meaningless without
a topology to resolve against:

- **`service.owning_domain`** — the business domain this repo belongs to
  (must be a key in `domain-topology.yaml`'s `domains:`).
- **`service.domain_role`** — `foundational | derived | aggregate`, DOMA's own
  classification. Must agree with the topology's declared role for that
  domain; a repo claiming a role its domain's topology entry does not have is
  a DIVERGENCE, same severity as any other claimed-vs-actual mismatch
  `prod-review` computes.
- **`domain_dependencies`** — a top-level list, each entry
  `{domain: <name>, via: <capability id>}`, naming every OTHER domain this
  service depends on and the specific capability it depends on. That
  capability MUST be classed `domain_gateway` (`tier-policy.yaml`
  `capability_classes.domain_gateway`) in the target domain's own spec.

## The invariant

**A service outside domain D may depend only on a capability of D's classed
`domain_gateway` — never on any other capability a D-owned repo declares**,
regardless of whether that other capability is technically reachable (same
network, same cluster, a shared database the owning team never locked down).
Every skill touch below exists to catch or prevent a violation of this one
sentence:

- reading another domain's datastore directly instead of calling its gateway;
- a `domain_dependencies` entry whose `via:` capability is not classed
  `domain_gateway` in the target's own spec;
- a `derived`/`aggregate` service quietly becoming the thing another service
  depends on for primitive data it doesn't own — the drift DOMA calls a
  domain slowly turning `foundational` by accretion, with nobody having
  declared it so.

`domain_gateway`'s own obligations (`tier-policy.yaml`) are what the GATEWAY
owes ITS consumers — versioning, backward-compat window, a consumer registry,
a deprecation policy. They compose with dimension 21's consumer-driven
contracts (verified in the provider's build) rather than replacing it: §21
proves the contract between two sides is honored once the dependency is
legitimate; this file's invariant is what decides whether it is legitimate at
all.

## What this cannot prove locally

Every skill in this suite operates on one repo checkout. Declaring
`domain_dependencies: [{domain: payments, via: payments_gateway}]` in THIS
repo's `production.yaml` does not prove the `payments` repo really exposes a
capability called `payments_gateway` classed `domain_gateway` — that fact
lives in a repo this skill run cannot see. What every DOMA-aware step below
CAN do:

- resolve `owning_domain`/`domain_role` against the local copy of
  `domain-topology.yaml` (a repo-external file, but a local one — no network
  call);
- flag a `domain_dependencies` entry whose `via:` target is absent from THIS
  repo's own capability list when it happens to be self-referential (rare,
  but a repo can depend on its own domain's other capabilities without
  crossing a boundary at all — that is not a violation and must not be
  flagged as one);
- otherwise, treat an unresolvable cross-repo claim as `required_evidence`
  rather than a pass: "the target repo's `payments_gateway` capability
  resolves to class `domain_gateway`" is a fact `prod-spec`/`prod-review`
  record as UNVERIFIED-CROSS-REPO, never as satisfied by assertion.

Verifying the topology globally — that no two domains both claim
`foundational` ownership of the same data, that a declared gateway really is
what callers reach — needs an org-level check run across every repo in
`domain-topology.yaml`, which is out of scope for any single skill run here.
That is future work, not a gap this file papers over.

## The registry: `registries/domain-boundaries.yaml`

Same shape as every other liability registry in this framework (owner,
`created`, `expires`) — a TEMPORARY, explicit exception to the invariant
above, e.g. during a migration where a caller still reads another domain's
store directly while its gateway is being built:

```yaml
# registries/domain-boundaries.yaml
- capability: legacy_payments_read     # the direct-access capability, named
  target_domain: payments
  reason: >
    checkout-svc reads payments' ledger table directly pending
    payments_gateway's read-path (T2 of the migration plan); tracked so the
    exception cannot go quiet.
  owner: checkout-team
  created: 2026-08-27
  expires: 2026-11-27
```

`prod-ops` OP-5 sweeps this registry exactly like `contract-debt.yaml`: past
`expires` with no fix ⇒ the suppressed boundary check returns to force and the
owner is notified, never a silently extended waiver.

## Where each skill touches this

- **`prod-new`** — folds domain classification into Phase 1's Q3 (Boundaries)
  when the topology file exists; never a fifth question.
- **`prod-bootstrap`** — Phase 1b derives topology presence; Phase 2 item 2
  proposes domain/role from the inventory the same way it proposes capability
  classes.
- **`prod-spec`** — `domain_gateway` joins the class→obligations table;
  `crosses_domain_boundary` joins the semantic-event list.
- **`prod-review`** — Phase 1 recomputes the domain-boundary claim from the
  diff; Phase 2 (and `review-depth.md` area 7) flags a direct-store dependency
  where a gateway was owed.
- **`prod-ops`** — OP-5 sweeps `domain-boundaries.yaml` liabilities.
