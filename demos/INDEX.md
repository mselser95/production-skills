# Demos — the step before a gate

Every dimension in this framework began as a claim somebody could not yet
verify. A demo is where that claim is made **executable on a laptop** before it
is imposed on a repo, and the order matters: this file's own policy says that
*every vacuous row began as a real requirement nobody could satisfy honestly
yet, and was therefore satisfied dishonestly.* Encoding an obligation in
`tier-policy.yaml` before the mechanism has been shown to work end to end is
how a gate people learn to route around gets built.

So a demo de-risks the mechanism, and only then does it travel. The template's
own `scripts/kill-durability.sh` is the worked example: it started as exactly
one of these — a script proving a property against a throwaway container — and
is now a vendored gate every scaffold ships.

## The rules a demo here obeys

Inherited from the first one (`image-signing-demo`) and non-negotiable, because
each exists to stop a specific way of lying:

- **It runs on a laptop, on throwaway containers, and touches nothing real.**
- **It must be able to fail.** Every demo carries a negative/control path,
  behind an env switch, that breaks the property on purpose and exits non-zero.
  A success path nobody has made fail is not validated — it is a story.
- **It reports the mechanism it actually used.** When the intended injector is
  unavailable, the demo says so in its own output and supplies an honest
  alternative. `power-loss-durability-demo` found `dm-flakey` absent from
  Docker Desktop's kernel, printed the inventory, and supplied its own NBD
  device rather than simulating quietly.
- **It is re-run from a clean clone of the pushed commit** before it is
  believed. Packaging gaps do not show up in the directory the author built in.
- **`teardown.sh` removes everything**, and the removal is verified, not
  assumed.

## How a demo becomes a practice in a new org

The demo itself never travels. What travels is the property, by one of two
vehicles, and every row below is labelled with which:

- **[A] per repo** — the mechanism is vendored into `prod-new`'s template
  (a script, a test, a conformance kit), a key lands in `tier-policy.yaml`, and
  a row lands in `verify-standard.sh` with its selftest. `prod-new` ships it to
  greenfield repos; `prod-bootstrap` turns it into a gap-report row and a plan
  task for brownfield ones. Every agent in a governed repo then meets it
  through the installed `AGENTS.md`.
- **[B] once per org** — the control is platform-level (an admission
  controller, a Vault, a prober). It is installed once from the demo's runbook,
  and what travels to each repo is only the *verification of participation*:
  a policy key plus a probe row asking whether this repo takes part.

A demo that never acquires a vehicle is debt, not an artifact — which is why
the status column exists and why `demo-only` is a visible state rather than a
quiet one.

## Status vocabulary

| status | meaning |
|---|---|
| `validated` | runs green here, negative path proven to fail, re-run from a clean clone |
| `vendored` | its mechanism ships in `prod-new/template/` |
| `gated` | a row in `verify-standard.sh` scores it, with selftest coverage |
| `queued` | on the list, not built |
| `blocked` | attempted, could not be made honest on this stack — with the reason |

## The demos

| # | demo | property it makes executable | source | cashes | vehicle | status |
|---|---|---|---|---|---|---|
| 1 | [image-signing-demo](https://github.com/mselser95/image-signing-demo) | an image cannot run unless signed by a key that never leaves the vault; the tag is rewritten to a digest at admission | Sigstore/cosign practice | `artifact_provenance`, supply chain | [B] | `validated` |
| 2 | [power-loss-durability-demo](https://github.com/mselser95/power-loss-durability-demo) | SIGKILL cannot tell fsync'd code from code that never calls it — only cutting the device can; a torn tail is refused, not read back as data | Pillai et al., ALICE (OSDI 2014) | narrows `assumed: fsync_bytes_reach_the_platter`; §12 durability trade | [A] | `validated` |
| 3 | [retry-storm-demo](https://github.com/mselser95/retry-storm-demo) | the naive variant stays collapsed 20s AFTER the trigger is removed; a global retry budget returns it in 1s | Bronson et al., Metastable Failures (HotOS 2021) | §26; `overload.retry_budget`, `overload.metastable_recovery` | [A] | `validated` |
| 4 | [gray-failure-demo](https://github.com/mselser95/gray-failure-demo) | the self-report stays `ready` through a fault costing clients a third of their requests; the self-emitted imitation of the client vantage stays silent through all of it | Huang et al., Gray Failure (HotOS 2017); Gunawi et al., Fail-Slow at Scale (FAST 2018) | §8, §22; `differential_observability.client_vantage_not_self_emitted` | [A]+[B] | `validated` |

### In flight

| demo | property | source | cashes |
|---|---|---|---|
| crypto-shredding-demo | a subject's data made unreadable in an append-only log AND in snapshots that already folded it, without rewriting history | Boneh & Lipton (USENIX Sec 1996) | §15 `deletion_mechanism: crypto_shredding` |
| coordinated-omission-demo | a closed-loop harness stalls with the system, so the requests that would have been slow are never issued | Tene (talk, 2015); Little (1961) | §25 `load_testing.generation: open_loop` |
| fencing-token-demo | a paused leader past its lease still writes, and only a monotonic token checked at the storage layer rejects it | Kleppmann (2016; DDIA ch.8) | §7; `source_of_truth.consistency_semantics` |

### Queued

Grouped by what they cash. Every one of these is an obligation this framework
already declares and that nothing currently executes — which is the selection
criterion, not novelty.

**Already-declared obligations with no executor:** backup-restore (`backup_restore_test`) · error-budget-freeze (`slo.exhaustion_policy: declared_and_enforced`) · runbook-rehearsal (`runbooks.exercise_cadence`) · trace-conformance (`formal_methods` at T0) · expand-contract-live (§19 `schema_evolution`) · partition-consistency (§20, the declared consistency model checked by nothing)

**Supply chain, extending demo #1:** slsa-provenance · reproducible-builds · transparency-log · dependency-confusion · sbom-runtime-drift · vuln-reachability

**Distributed resilience:** asymmetric-partition · clock-skew · fail-slow-disk · bulkhead · dedup-end-to-end · chaos-steady-state

**Runtime security:** dynamic-credentials · workload-identity · syscall-anomaly · egress-default-deny · least-privilege-rbac · config-error

**Capacity and delivery:** usl-fit · canary-abort · noisy-neighbor · flag-lifecycle

## What is NOT here, and why

- **CHESS/Coyote-style systematic schedule exploration** — no mature Go
  implementation exists, and a demo whose harness cannot exist would be a gate
  nothing can run. The repo's own lesson stands instead: a probabilistic
  concurrency test is not a gate (`-race -count=N -shuffle` plus forcing the
  interleaving by hand).
- **Hedged requests as an obligation** — Dean & Barroso propose them for
  large read fan-outs; on an external-effect path they duplicate the effect.
  §26 carries them as a cited tactic, never as a class obligation.
