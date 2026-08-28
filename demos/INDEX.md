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

**One consequence of idempotency, stated because it cost a wrong diagnosis:**
every demo recreates its own fixed-name containers, so TWO CONCURRENT RUNS OF
THE SAME DEMO destroy each other. The per-demo prefix rule prevents collisions
between different demos and does nothing about this. Validate a demo only after
its authoring run has finished; when a failure shows a different symptom on each
attempt, that is a concurrency signature rather than a defect signature, and the
container ages in `docker ps -a` are what tell you.

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
| 5 | [crypto-shredding-demo](https://github.com/mselser95/crypto-shredding-demo) | a subject is erased from an append-only log AND from a snapshot that already folded them in, by destroying their key — log byte-identical, replay still green, everyone else untouched | Boneh & Lipton (USENIX Sec 1996) | §15 `deletion_mechanism: crypto_shredding` | [A] | `validated` |
| 6 | [fencing-token-demo](https://github.com/mselser95/fencing-token-demo) | a leader SIGSTOPped past its lease still writes; only a monotonic token checked at the store refuses it — and B writes again after, which is what makes it a fence rather than an outage | Kleppmann (2016); DDIA ch.8 | §7; `source_of_truth.consistency_semantics` | [A] | `validated` |
| 7 | [coordinated-omission-demo](https://github.com/mselser95/coordinated-omission-demo) | same service, same stall, same offered rate: closed loop reports p99 14.6ms, open loop 3859ms — 264x — and the service itself counts the 1594 arrivals the closed loop never issued | Tene (talk, 2015); Little (1961) | §25 `load_testing.generation: open_loop` | [A] | `validated` |
| 8 | [backup-restore-demo](https://github.com/mselser95/backup-restore-demo) | a restore checked by row count passes over a corrupted ledger that the invariant check refuses | SRE (O'Reilly 2016), data-integrity ch. | `backup_restore_test` | [A] | `pushed` |
| 9 | [vuln-reachability-demo](https://github.com/mselser95/vuln-reachability-demo) | "govulncheck is green" and "no known-vulnerable dependencies" are different claims, and the count is a property of the toolchain | govulncheck / SBOM tooling semantics | §9 `vuln_scan` | [A] | `pushed` |
| 10 | [expand-contract-live-demo](https://github.com/mselser95/expand-contract-live-demo) | a schema change under live traffic with two app versions running at once, zero failed requests — and the one-shot ALTER measured holding ACCESS EXCLUSIVE on a rehearsal | Rae et al., F1 (VLDB 2013) | §19 `schema_evolution` | [A] | `pushed` |
| 11 | [dependency-confusion-demo](https://github.com/mselser95/dependency-confusion-demo) | a committed, integrity-checked lockfile generated against the wrong default is a durable pin TO THE ATTACKER that `npm ci` reproduces on every clean build | Birsan (2021, disclosure) | §23; **corrects** `dependency_currency.lockfile` | [A]+[B] | `pushed` |
| 12 | [clock-skew-demo](https://github.com/mselser95/clock-skew-demo) | 8 of 15 causal edges invert under wall-clock ordering, 0 under HLC — and 8 are ordered by the logical counter alone, the component an incomplete implementation drops | Kulkarni et al., HLC (OPODIS 2014); Lamport (1978) | the injected clock/random/ID rule — this demo is WHY | [A] | `pushed` |
| 13 | [bulkhead-demo](https://github.com/mselser95/bulkhead-demo) | a healthy endpoint collapses because a sick one shares its pool; enlarging the shared pool postpones exhaustion instead of confining it | Nygard, *Release It!* (2018); SRE ch.22 | §7 `isolation_and_backpressure`, §26 | [A] | `pushed` |

`validated` above means I re-ran it myself from a clean clone of the pushed
commit, watched the success path exit 0 AND every negative control exit
non-zero. `pushed` means its author reported that and I have not yet repeated
it — the distinction is kept because the whole programme rests on not believing
a report.

### In flight

sbom-runtime-drift · reproducible-builds · dedup-end-to-end

### Queued

Grouped by what they cash. Every one is an obligation this framework already
declares and that nothing currently executes — the selection criterion is that
gap, never novelty. Rewritten from the delivered set rather than edited in
place, after a careless string replacement in an earlier pass fused two names
and left three delivered demos still listed as pending.

**Already-declared obligations with no executor** — error-budget-freeze
(`slo.exhaustion_policy: declared_and_enforced`) · runbook-rehearsal
(`runbooks.exercise_cadence`) · trace-conformance (`formal_methods` at T0) ·
partition-consistency (§20, the declared consistency model checked by nothing)

**Supply chain, extending demo #1** — slsa-provenance · transparency-log

**Distributed resilience** — asymmetric-partition · fail-slow-disk ·
chaos-steady-state

**Runtime security** — dynamic-credentials · workload-identity ·
syscall-anomaly · egress-default-deny · least-privilege-rbac · config-error

**Capacity and delivery** — usl-fit · canary-abort · noisy-neighbor ·
flag-lifecycle

Most of what remains needs a kubernetes cluster; the batches so far
deliberately took the docker-only ones first, because they run in parallel
without contending for a cluster.

## What is NOT here, and why

- **CHESS/Coyote-style systematic schedule exploration** — no mature Go
  implementation exists, and a demo whose harness cannot exist would be a gate
  nothing can run. The repo's own lesson stands instead: a probabilistic
  concurrency test is not a gate (`-race -count=N -shuffle` plus forcing the
  interleaving by hand).
- **Hedged requests as an obligation** — Dean & Barroso propose them for
  large read fan-outs; on an external-effect path they duplicate the effect.
  §26 carries them as a cited tactic, never as a class obligation.
