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
| `pushed` | built and published, and its happy path was seen to run **once, on the machine that built it**. The negative path was not separately proven, and it was not re-run from a clean clone. |
| `validated` | runs green here, negative path proven to fail, re-run from a clean clone |
| `vendored` | its mechanism ships in `prod-new/template/` |
| `gated` | a row in `verify-standard.sh` scores it, with selftest coverage |
| `queued` | on the list, not built |
| `blocked` | attempted, could not be made honest on this stack — with the reason |

**Where this table actually stands, counted from the rows below rather than
remembered: 11 `pushed`, 23 `validated`.** `pushed` was missing from this
vocabulary until 2026-08-29 — 27 of 34 rows carried a status the legend did not
define, so a reader looking it up found nothing and would reasonably read it as
a synonym for the one above it. It is not. The gap between the two is the whole
point of having a status column:

- **`pushed` is a publication fact.** The repository exists, its README is real,
  and the mechanism ran. That is worth something and it is not verification.
- **`validated` is a claim about the negative path** — that the demo FAILS when
  the property it demonstrates is removed. A demo whose failing case was never
  exercised is the same shape as a test that passes against a broken
  implementation: it proves the harness runs, not that the mechanism matters.

**The procedure is a script: `demos/validate-demo.sh <repo>`.** It clones fresh
from the public URL every time, runs the happy path, reads the controls out of
the runner's own header, and requires every one of them to exit 1. Zero declared
controls is a refusal, not a pass.

It was checked against a demo whose answer was already known (clock-skew-demo:
4 controls, all 1) and, more importantly, watched REJECT three things: a demo
whose declared control exits 0 anyway, a runner declaring no control at all, and
a repo that does not clone. A validator nobody has seen say no is
indistinguishable from one that always says yes — which is the very shape it
exists to catch in the demos.

**What promoting one actually costs, measured on the first one (2026-08-29,
`usl-fit-demo`, row 22).** The demo publishes its own contract in its runner's
header: `./run-demo.sh` exits 0, and five named controls each exit 1. Validating
it meant running all six from a CLEAN CLONE of the public repo, not from the
working copy that built it:

    ./run-demo.sh                              -> exit 0
    USL_CONTROL=short-range                    -> exit 1
    USL_CONTROL=no-serialization               -> exit 1
    USL_CONTROL=unmodelled-regime              -> exit 1
    USL_CONTROL=unsaturated                    -> exit 1
    USL_CONTROL=closed-loop                    -> exit 1

Six runs, roughly twenty minutes of wall clock, and the clean clone is the part
that cannot be skipped: a demo that only runs where it was written is a demo
with an undeclared dependency on that machine.

That is the unit of work behind each of the 26 remaining rows. It is why the
column says `pushed`.

Promoting a row from `pushed` to `validated` means doing that work, not editing
this cell. Nothing here should be described as "34 validated demos"; the honest
sentence is "34 published, 7 validated".

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
| 8 | [backup-restore-demo](https://github.com/mselser95/backup-restore-demo) | a restore checked by row count passes over a corrupted ledger that the invariant check refuses | SRE (O'Reilly 2016), data-integrity ch. | `backup_restore_test` | [A] | `validated` |
| 9 | [vuln-reachability-demo](https://github.com/mselser95/vuln-reachability-demo) | "govulncheck is green" and "no known-vulnerable dependencies" are different claims, and the count is a property of the toolchain | govulncheck / SBOM tooling semantics | §9 `vuln_scan` | [A] | `validated` |
| 10 | [expand-contract-live-demo](https://github.com/mselser95/expand-contract-live-demo) | a schema change under live traffic with two app versions running at once, zero failed requests — and the one-shot ALTER measured holding ACCESS EXCLUSIVE on a rehearsal | Rae et al., F1 (VLDB 2013) | §19 `schema_evolution` | [A] | `pushed` |
| 11 | [dependency-confusion-demo](https://github.com/mselser95/dependency-confusion-demo) | a committed, integrity-checked lockfile generated against the wrong default is a durable pin TO THE ATTACKER that `npm ci` reproduces on every clean build | Birsan (2021, disclosure) | §23; **corrects** `dependency_currency.lockfile` | [A]+[B] | `validated` |
| 12 | [clock-skew-demo](https://github.com/mselser95/clock-skew-demo) | 8 of 15 causal edges invert under wall-clock ordering, 0 under HLC — and 8 are ordered by the logical counter alone, the component an incomplete implementation drops | Kulkarni et al., HLC (OPODIS 2014); Lamport (1978) | the injected clock/random/ID rule — this demo is WHY | [A] | `validated` |
| 13 | [bulkhead-demo](https://github.com/mselser95/bulkhead-demo) | a healthy endpoint collapses because a sick one shares its pool; enlarging the shared pool postpones exhaustion instead of confining it | Nygard, *Release It!* (2018); SRE ch.22 | §7 `isolation_and_backpressure`, §26 | [A] | `validated` |
| 14 | [sbom-runtime-drift-demo](https://github.com/mselser95/sbom-runtime-drift-demo) | the application's OWN binary appears in zero SBOM components (syft derives its file inventory from the package DB), and a package-DB check passes while an LD_PRELOADed object executes | CycloneDX / SPDX specs; EO 14028 | §9 `supply_chain.sbom` | [A]+[B] | `validated` |
| 15 | [reproducible-builds-demo](https://github.com/mselser95/reproducible-builds-demo) | two builders differing in image, path, HOME, hostname, uid, timezone and VCS state produce byte-identical digests — with per-flag attribution showing which bytes each flag removes | Lamb & Zacchiroli (IEEE Software 2022) | §11 reproducibility; complements `artifact_provenance` | [A]+[B] | `validated` |
| 16 | [dedup-end-to-end-demo](https://github.com/mselser95/dedup-end-to-end-demo) | duplicates injected at every hop of a three-service chain still yield exactly one effect — and the key minted per PUBLISH instead of per outbox ENTRY defeats it | Richardson, *Microservices Patterns* (2018); Gray & Reuter (1992) | `external_effect.idempotency_strategy` | [A] | `validated` |
| 17 | [canary-abort-demo](https://github.com/mselser95/canary-abort-demo) | the degraded canary PASSES latency (27µs shift, p=0.91) and error rate, and returns 200 to everything — only the service's own conservation counter sees it; a timer-only "canary" creates no AnalysisRun at all | SRE (2016); Kayenta as tooling | §17; `delivery.analysis: automated_plus_invariant_gates` | [A]+[B] | `pushed` |
| 18 | [egress-default-deny-demo](https://github.com/mselser95/egress-default-deny-demo) | default-deny turns direct and metadata egress into connection errors, and the DNS payload still walks out under the complete, correct allowlist — NetworkPolicy is L3/L4 and the secret is at L7 | NIST SP 800-207; the NetworkPolicy spec | proposes a NEW egress key (§9 has none) | [B] | `pushed` |
| 19 | [noisy-neighbor-demo](https://github.com/mselser95/noisy-neighbor-demo) | an unlimited pod degrades its neighbour on a shared node; limits-without-requests yields Burstable and still starves it — the QoS class, not the YAML's appearance, is what the kubelet acts on | k8s resource-management docs; SRE ch.22 | `deployment_resource_limits` — declared, never exercised | [A]+[B] | `pushed` |
| 20 | [dynamic-credentials-demo](https://github.com/mselser95/dynamic-credentials-demo) | a leaked STATIC credential still works at t+300 and survives a full redeploy of the app that owned it; the dynamic one is dead at its TTL. A `;` inside a SQL COMMENT made `vault lease revoke` a no-op that exited 0 | Saltzer & Schroeder (Proc. IEEE 1975) | `signer.key_custody` | [A]+[B] | `validated` |
| 21 | [flag-lifecycle-demo](https://github.com/mselser95/flag-lifecycle-demo) | an expiry that reddens the build is the only thing that removes a dead flag; the entry deleted while the code still branches on it is worse, because it is silent | Humble & Farley (2010); Fowler toggles (2017) | `liability_registries`; prod-ops OP-5 | [A] | `validated` |
| 22 | [usl-fit-demo](https://github.com/mselser95/usl-fit-demo) | the knee a per-operation benchmark cannot see, because both terms that produce it vanish at N=1 — fitted, then MEASURED at the prediction | Gunther, *Guerrilla Capacity Planning* (2007); Amdahl (1967) | §25 saturation; `capacity.margin_target` | [A] | `validated` |
| 23 | [trace-conformance-demo](https://github.com/mselser95/trace-conformance-demo) | a NARRATED trace conforms to a strict spec while the same run loses an effect — the code's model of itself is consistent precisely where the code is wrong for reasons its author did not think of | Lamport (2002); Davis et al., eXtreme Modelling (VLDB 2020) | `formal_methods` at T0 | [A] | `validated` |
| 24 | [transparency-log-demo](https://github.com/mselser95/transparency-log-demo) | an inclusion proof recomputed OFFLINE, not asked of the log; a tampered leaf diverges from the signed tree head | Newman et al., Sigstore (CCS 2022); RFC 6962; Merkle (1987) | `artifact_provenance` | [B] | `validated` |
| 25 | [config-error-demo](https://github.com/mselser95/config-error-demo) | a wrong-unit value starts fine and misbehaves under load; a syntax-only gate accepts all three broken configs | Xu et al., SOSP 2013 | §10 operability | [A]+[B] | `validated` |
| 26 | [partition-consistency-demo](https://github.com/mselser95/partition-consistency-demo) | the same cluster, workload and checker with NO partition finds zero anomalies and names itself the vacuous form — the run most "consistency testing" actually performs | Kingsbury & Alvaro, Elle (PODC 2021) | §20; `consistency_verification` | [A]+[B] | `pushed` |
| 27 | [asymmetric-partition-demo](https://github.com/mselser95/asymmetric-partition-demo) | the partitions that break systems are partial and one-way, not the clean split everyone tests | Alquraan et al. (OSDI 2018) | §20; the `partition` scenario is three | [B]+[A] | `pushed` |
| 28 | [chaos-steady-state-demo](https://github.com/mselser95/chaos-steady-state-demo) | an abort path that was never rehearsed fails when invoked, and the experiment continues past its own abort | Basiri et al. (IEEE Software 2016) | `chaos_engineering` (all three sub-keys) | [B]+[A] | `pushed` |
| 29 | [workload-identity-demo](https://github.com/mselser95/workload-identity-demo) | SPIRE perfect, SVIDs rotating, window bounded — and the service keeps a compat door open on the shared secret: bounded for ONE of its two doors | SPIFFE/SPIRE spec; BeyondCorp (2014) | `signer.key_custody`, service-to-service | [B] | `validated` |
| 30 | [syscall-anomaly-demo](https://github.com/mselser95/syscall-anomaly-demo) | Falco with an EMPTY rules file starts cleanly, reports healthy, and detects nothing; rules find what somebody thought of | Forrest et al. (IEEE S&P 1996); Falco as tooling | §9 — proposes a NEW runtime-security key | [B] | `pushed` |
| 31 | [least-privilege-rbac-demo](https://github.com/mselser95/least-privilege-rbac-demo) | the gap between the role somebody guessed and the role the workload uses, measured — and a derived role nobody re-tested is an outage waiting for a code path | Saltzer & Schroeder (1975); k8s RBAC docs | `authz_invariants` | [A]+[B] | `pushed` |
| 32 | [slsa-provenance-demo](https://github.com/mselser95/slsa-provenance-demo) | a correctly SIGNED artifact built by hand is admitted by signature and refused by provenance — and the shipped probe row gives the SAME verdict to a sign-only and a with-provenance workflow | Torres-Arias et al., in-toto (USENIX Sec 2019); SLSA spec | `artifact_provenance` — **and finds the row vacuous** | [B] | `validated` |
| 33 | [error-budget-freeze-demo](https://github.com/mselser95/error-budget-freeze-demo) | an SLI computed from the server's own success counter stays healthy through an outage the client sees, so the budget never burns and the freeze never fires | Beyer et al., SRE (2016) | `slo.exhaustion_policy: declared_and_enforced` | [A]+[B] | `pushed` |
| 34 | [runbook-rehearsal-demo](https://github.com/mselser95/runbook-rehearsal-demo) | a runbook whose steps assert no postcondition: every command exits 0, the service is still broken, the rehearsal reports success | SRE (2016); §10's own citations-resolve line | `runbooks.exercise_cadence` | [A] | `pushed` |

`validated` above means I re-ran it myself from a clean clone of the pushed
commit, watched the success path exit 0 AND every negative control exit
non-zero. `pushed` means its author reported that and I have not yet repeated
it — the distinction is kept because the whole programme rests on not believing
a report.

### In flight

(none — all 34 delivered)

### Queued

Nothing. The 34-demo programme is complete: every row above is a public repo
with a `run-demo.sh` that exits 0, at least one control that exits non-zero,
and a `teardown.sh` that COUNTS what survives rather than trusting an exit code.

## What is NOT here, and why

- **CHESS/Coyote-style systematic schedule exploration** — no mature Go
  implementation exists, and a demo whose harness cannot exist would be a gate
  nothing can run. The repo's own lesson stands instead: a probabilistic
  concurrency test is not a gate (`-race -count=N -shuffle` plus forcing the
  interleaving by hand).
- **Hedged requests as an obligation** — Dean & Barroso propose them for
  large read fan-outs; on an external-effect path they duplicate the effect.
  §26 carries them as a cited tactic, never as a class obligation.
