# Acceptance checklist for the greenfield template

Measured from the one repo known to be AT the standard after a full adversarial
audit and a `prod-review` pass (clcsolutions/binance-marketdata `standard/v1`,
2026-08-17). The template is not required to match the numbers — that repo has
a real domain — but every MECHANISM below must be present and exercised, since
each one exists because its absence was a finding.

The single acceptance test: **`scripts/verify-standard.sh` reports zero FAIL on
the empty service.** This file is what to check when a probe passes but the
mechanism is hollow.

| Mechanism | Reference | Template requirement |
|---|---|---|
| Zone enforcement | `internal/architecture/boundaries_test.go`, 4 rules | present; domain imports nothing internal; app forbids adapter+platform; adapter/in forbids adapter/out; adapter/out + platform forbid app |
| Wall-clock ban | allowlist entries: **0** | present, matching the IDENTIFIER `time.Now` (not `time.Now(` — a function value slipped past that once), allowlist empty and commented |
| Injected clock | `HubOptions.Now` pattern | clock, randomness and IDs are injected ports with deterministic fakes |
| Tracing port | 8 files in `internal/platform/observability` | port + no-op default + structured-log adapter, zero non-stdlib deps |
| Tracer WIRED | both `cmd/*/main.go` | wired at the composition root — a port nobody injects is a no-op in production (this shipped broken once) |
| Build identity | `internal/platform/buildinfo` | revision + build time via `ReadBuildInfo`, and `.dockerignore` must NOT exclude `.git` (that emptied revision in every image) |
| Config identity | `config_identity.go` | `Digest()` covering EVERY behavior-defining input, including ones read outside the config struct |
| Outbox / journal | **absent by ratified decline** (no durable effects) | PRESENT in the template: it has durable effects by design; intent journaled before the effect, idempotency key generated INSIDE the retry closure |
| Conformance kits | 6 kits, 4 adapters wired | one kit per class in tier-policy, at least one adapter wired, README stating a scenario addition is a policy change |
| Ratified invariants | 3 ratified + 1 pending, non-vacuity recorded ×3 | ≥2 seed invariants, each with its mutation APPLIED, observed red, reverted, recorded |
| Ratification packages | 4 in `.prod/ratify-queue/` | one per seed invariant, both-direction evidence + contradiction-check + what-breaks-if-wrong |
| Property tests | 10, with generator adequacy | ≥2 over the core, each asserting its own generator's state diversity and discard ceiling |
| Fuzz | 5 targets + seed corpora | one per decode boundary, corpus checked in, each executed |
| Replay corpus | 5 fixtures, 5/5 counterexamples verified red | harness + ≥1 fixture proven red under a deliberate mutation |
| Observability contracts | metrics + spans manifests + contract tests | both manifests, and a test that scrapes the REAL endpoint failing on drift in BOTH directions |
| Invariant counters | 5 `INVARIANT` series | one per ratified invariant, asserted 0 in normal operation AND asserted to increment under a deliberately violating call |
| Registries | 4 files + `check-registries.sh` | all four, and the EXPIRY CHECKER (recording without enforcement is a permanent silent exemption) |
| Coverage | ratchet floors + changed-line signal | per-package floors that fail on an unresolvable package, plus changed-line as a signal that always exits 0 |
| Probe vendored | `scripts/verify-standard.sh` | vendored, `make verify-standard`, and its own CI job |
| Evidence record | `.prod/evidence/<sha>.json` | emitted by the probe — ephemeral stdout is not a record |
| Mutation | baseline + real nightly invocation | a runnable script; the nightly job must NAME the real command, never echo a placeholder |
| Profiling | capture script + env-gated live endpoint | both halves; the live endpoint on its OWN listener, never the health port, never in a Service |
| Ops docs | RUNBOOK, SLO (proposed), alerts, CODEOWNERS | all four; every metric/env var cited must resolve; CODEOWNERS with a RESOLVABLE handle (a placeholder gates nothing) |
| Make targets | 13 | check-fast, test, race, lint, architecture, coverage, chaos, e2e, fuzz, bench, test-advisory, verify, verify-standard, check-registries |
| CI jobs | 10 staged + nightly | check-fast gates the full lane; advisory is continue-on-error; required names never renamed |
| Spec shape | `verified:`/`assumed:` per capability, 7 declines with reasons | the split present, every decline carrying its reason, and NO invented key holding unmet obligations (they are waivers) |
| Dependencies | 8 (real domain) | **0 non-stdlib** — achievable and proof the mechanisms need no framework |

## The traps this list exists to catch

Each was a real finding, not a hypothetical:

1. A port with no injection at the composition root (tracing shipped no-op).
2. A gate that checks wiring instead of effect (`revision` empty in every image).
3. A manifest nobody compares to reality (documentation drift).
4. An invariant test that passes on the code it names (substantive vacuity).
5. A scenario denominator the author can shrink (4 of 10 capabilities).
6. A registry with no expiry enforcement (permanent silent exemption).
7. A coverage floor measured on a different tree (stale, not enforced).
8. A candidate test in the blocking lane (unverified oracle gating).
9. `t.Skip`/`echo` standing in for a mechanism (mutation lane).
10. A test helper that closes and re-binds a port (a TOCTOU flake class).
