# GAP REPORT — mselser95/production-skills (tier T1)

Produced by `prod-bootstrap` Phase 4 on 2026-08-29. One row per dimension in
`_shared/dimensions.md` — **27 of them**, walked rather than recalled, because a
count written down here would silently retire whichever dimension was added
last.

**Read the toolchain row (CI-1) first.** It changes how every Go-bound row below
should be read: `_shared/probes/verify-standard.sh` implements the Go toolchain
only and REFUSES to run here (`detected 'unknown'`, exit 2). That refusal is
correct and it is not a gap that can be closed by vendoring the probe — a
vendored probe that refuses to run is a gate the repo believes it has and does
not. The gate that exists here instead is `make verify`, built today.

`not applicable` appears only with the PROPERTY that produced it. `N/A` alone is
not a legal state.

---

## The 27 dimensions

| # | dimension | requirement (T1) | current state | gap | sev |
|---|---|---|---|---|---|
| 1 | Correctness — structural | build, vet, lint, unit tests, fitness | `make check-fast`: actionlint + shellcheck (36 unique of 62, `-S error`) + 4 probes; `make verify` adds 6 selftests + TCB. Wired into the pre-commit hook and CI **today**. All four targets mutation-proven to go red. | none | — |
| 2 | Correctness — fault sensitivity | race detector / TSan equivalent | not applicable: no concurrent execution path exists. `install.sh` and every probe are single-process and sequential; there is no second thread for a detector to observe. | none | — |
| 3 | Invariants and properties | ratified, provably non-vacuous | 3 invariants PROPOSED in `.prod/ratify-queue/`, each `PENDING-HUMAN` with a `non_vacuity_check` whose mutation was RUN, not written. `verification/ratified/` is deliberately empty — bootstrap never writes it. | **ratification is unfinished, and only a human can finish it** | med |
| 4 | Scenarios — failure-mode matrix | real denominator, no `blocked` rows | `.prod/failure-modes.md`: 14 rows = 2 capabilities × the 7 scenarios `source_of_truth` declares. 6 tested with quoted output, 8 not-applicable with properties, **0 blocked, 0 untested**. | none | — |
| 5 | Integration and contracts | the real-dependency lane actually RUN | `install.sh` e2e in CI against a throwaway config dir, **plus a `scaffold` job added in this change** that instantiates the template (contents AND paths), builds it, stamps provenance and runs the scaffold's own `make check-fast`. Measured by hand first: a correct instantiation reaches check-fast rc 0 and `verify-standard` PASS 64 / FAIL 3 / NA 18, all three FAILs being prod-new Phase-3 steps a machine cannot do — which is why the job gates on check-fast and not on verify-standard. | closed for check-fast; `verify-standard` on a scaffold is still human-gated by design | low |
| 6 | Performance and capacity | benchmarks + recorded baselines | not applicable as a request path (see `out_of_scope.load_baseline`: no offered load exists). The real cost is gate runtime, now measured: check-fast 9.9s, of which shellcheck 4.5s after content-dedup (was 29.8s), probes 5.9s. | no recorded baseline file for gate runtime | low |
| 7 | Resilience and recovery | recovery tested, not asserted | `--verify` now has three distinct exit codes (1 drift / 2 stale / 3 writable), each proven red-then-green by mutation. Restore = clone, tested: a fresh clone reinstalls to a byte-identical 309-file manifest. | none | — |
| 8 | Observability | metrics/spans contracts checked in CI; tracing wired in `cmd/` | not applicable: nothing here is deployed, so there is no running process to emit a series or a span. The gates' own output is the observability surface, and every failure branch names the FILES rather than a count — checked today for drift, staleness, writability and staleness-mapping. | none | — |
| 9 | Security | govulncheck blocking, secret scanning every trigger, SBOM, provenance | `govulncheck`/`gosec` are Go-bound and this repo has no Go (gosec IS wired, blocking and pinned `v2.21.4`, in the template it vends). **Secret scanning was absent until this change** and is now a BLOCKING step: gitleaks pinned `v8.21.2` over full history (`fetch-depth: 0`, without which it would scan one commit and report clean). Proven non-vacuous — and the first attempt was a false negative worth keeping: AWS's own documentation keys are allowlisted, so they found nothing; non-allowlisted keys found 2. | no SBOM or build provenance for this repo's own artifacts | med |
| 10 | Deployability and operability | runbook, required contexts, reconcilers | not deployed. Operability here is "a gate went red, now what", and each failure message carries its own next step (`Re-run install.sh only after reviewing the change`). | no runbook document; the messages carry it instead | low |
| 11 | Reproducibility | per-commit evidence record from CI on a clean tree | the template produces one (`.prod/evidence/…json`, seen in today's scaffold run, correctly marked `working tree DIRTY: NOT an attestation`). **This repo produces none.** | **no evidence record per commit** | med |
| 12 | Scalability | vertical/horizontal headroom | not applicable: no request path and no instance count. The only quantity that grows is repo size, and the gates are linear in it. | none | — |
| 13 | Bounded auto-recovery | a bounded retry/repair loop | not applicable: nothing runs continuously. Every effect is a one-shot local command a human invoked; there is no loop to bound. | none | — |
| 14 | The published contract | detect breaking changes to what consumers parse | partial. Consumers are scaffolded repos, and their contract is the template's shape; `check-template-drift.sh` is the consumer-side mechanism and fails closed on both a missing and an empty stamp (both proven today, exit 2). | no producer-side check that a template change is breaking | med |
| 15 | Data lifecycle | retention, deletion, PII | not applicable: the repo stores no records about anyone. Its durable state is source text under git. | none | — |
| 16 | Wiring — mechanisms DRIVEN, not present | every mechanism invoked by something | **this dimension produced this change's largest finding.** `row-vacuity-sweep.sh` was invoked by CI zero times and by the hook zero times while being wired into the template it vends; `check-registries.sh` ran only as a selftest and never looked at this repo's own registries. Both now run via `make check-fast` in both surfaces, and `probe-wiring.sh` now GATES the property with an 11-case selftest — including the substring false negative and the false-orphan-on-glob that review caught in it. | closed | — |
| 17 | Progressive delivery | canary/rollback | not applicable: nothing ships this repo to an environment. Distribution is `install.sh` on a developer machine and `git clone` for the template; there is no artifact for a rollback to re-pin. | none | — |
| 18 | Static analysis — SAST | semantic dataflow, blocking | `shellcheck -S error` across 36 unique scripts, blocking in both surfaces, mutation-proven. That is lint-grade, not dataflow-grade — there is no shell equivalent of a taint analysis here. | severity=warning findings are unreviewed (11 latent `GREPQ-UNDER-PIPEFAIL` in the template's own hygiene lane) | low |
| 19 | Schema evolution | breaking-change detection | the schemas are `tier-policy.yaml` keys and SKILL.md frontmatter. `policy-coverage.sh` detects a key with no row (proven today: injected key → red). **It does not detect the reverse** — a row scoring a key that no longer exists measures nothing and passes. | **one-directional check** | med |
| 20 | Chaos + consistency vs history | experiments, history checker | not applicable: not deployed, so there is no steady state to perturb and no concurrent writer to produce a history. The analogous instrument — mutating each probe row and requiring red — is done, 72 of 72. | none | — |
| 21 | Consumer-driven contracts | consumers verify the producer | partial, and the consumer side is real: a scaffolded repo runs `check-template-drift.sh` against the installed template. | consumers cannot pin a template VERSION; the stamp records files, not a release | med |
| 22 | SLO / error budget as a mechanism | objectives ratified, budget computed | not applicable: no service, no availability to promise. (The template's own `slo-objectives-ratified` row FAILs correctly in a raw copy — 3 SLIs, 0 ratified — because ratification is a prod-new Phase-3 human step.) | none | — |
| 23 | Dependency currency and pinning | pinned tool versions | actionlint pinned `v1.7.7` in CI; gosec pinned `v2.21.4` in the template. `shellcheck` and `PyYAML` use whatever the runner ships. | 2 unpinned tools in the gate path | med |
| 24 | Domain ownership / cross-domain | topology-aware boundaries | not applicable **by the skill's own rule**: `_shared/domain-topology.yaml` does not exist, so this dimension is skipped for this repo rather than answered. | none | — |
| 25 | Load, stress, soak | measured saturation point | not applicable: no request path (see dimension 6 and `out_of_scope.load_baseline`). | none | — |
| 26 | Overload and metastability | shedding, retry budget | not applicable: same property as 25 — nothing offers load, so there is no knee to fall off. | none | — |
| 27 | Deterministic simulation (advisory) | seeded sim lane | not applicable: no concurrent or time-dependent state machine to simulate. The template ships a sim lane; this repo has nothing for it to drive. | none | — |

## The rows humans forget (required by Phase 4)

| row | state | gap | sev |
|---|---|---|---|
| coverage today vs tier signal | no coverage instrument exists for shell; the 6 selftests are the unit tests | no coverage number at all | low |
| tests/prod LOC ratio (informational) | 6 selftests + 13 skills-static fixtures against 62 scripts | informational only | — |
| mutation baseline | no artifact; mutation is applied MANUALLY and universally (72/72 probe rows, 4 Makefile targets, 3 install.sh branches today) | no recorded baseline to trend | low |
| fuzz coverage of decode boundaries | the parsers are `grep`/`awk`/PyYAML over repo-controlled files; no untrusted input crosses a boundary | not applicable — property named | — |
| failure-mode matrix completeness | 14/14, 0 blocked | none | — |
| integration fidelity | install.sh e2e against a real filesystem ✓; template instantiation ✗ | see dimension 5 | high |
| compatibility / breaking change | see dimensions 14, 19, 21 | one-directional | med |
| benchmark baseline + capacity margin | 7 committed scorecards, all 10–12 days older than the SKILL.md they score; `benchmark-currency.sh` reports this ADVISORY in CI | stale by design (refresh needs credentials CI lacks) | low |
| recovery / reconciliation / restore | restore tested (clone → identical manifest); reconciliation declined with property | none | — |
| observability contract | see dimension 8 | none | — |
| supply-chain gates | SBOM ordering selftest ✓ (for the template); secret scanning ✗; provenance/attestation ✗ | see dimension 9 | high |
| delivery / rollback / runbooks | declined with property (dimension 17) | no runbook (dimension 10) | low |
| **BLOCKING gates whose check context is in the forge's REQUIRED list** | **UNKNOWN — not checked.** This must be read from the forge, never from the workflow file, and I did not query it. | unanswered | med |
| declared surfaces no reconciler applies | none declared | not applicable | — |
| declared backends with no producer | none declared | not applicable | — |

---

## Severity summary

- **high (0).** Both of this report's original high rows — no template instantiation (dim 5) and no secret scanning (dim 9) — are closed by the change this report ships with, and the rows above say so rather than describing the repo as it was an hour earlier. A gap report that contradicts its own commit is worse than none: a reader either redoes closed work or trusts that a blocking gate is missing.
- **med (7, one added by this change's own review):** invariant ratification pending (3); no evidence record (11); no wiring gate (16); no producer-side breaking-change check (14); one-directional policy check (19); no template versioning for consumers (21); 2 unpinned tools (23); required-contexts unverified.
- **low (5):** gate-runtime baseline, runbook, SAST warnings, coverage, mutation baseline.
- **not applicable (12),** each with the property that produced it.

## What this report does NOT claim

- **The forge's required-contexts list was not read.** Everything above about
  "blocking" comes from workflow files, which is exactly the source
  `dimensions.md` §10 says not to trust for this question. It is listed as
  unanswered rather than answered `ok`.
- **`verify-standard.sh` never ran against this repo** and cannot. Every row
  above was resolved by reading the repo and running its own gates, not by that
  probe. The 27 dimensions were walked by hand; a walked list is a weaker
  denominator than an executed one, and that is the cost of the toolchain gap.
- **The TCB does not cover this repo's own tooling, and that is by design, not an oversight.**
  `install.sh --verify` hashes what the skills DISTRIBUTE: each skill's tree,
  which reaches the two shared probes its text references (`verify-standard.sh`,
  `non-vacuity-selftest.sh`) through symlinks in `references/probes/`. The
  repo-level gates — the `Makefile`, `.githooks/`, and the other
  `_shared/probes/*.sh` including `probe-wiring.sh` — are absent from the
  manifest and are protected by git review instead. Checked, not assumed: after
  adding three probes the manifest stayed at 309 files. Anyone reading "TCB
  verified: 309 files" as covering the gates themselves would be wrong, which is
  why it is written down here.

- **The scaffold measurement is one run, on one machine, by hand.** PASS 64 /
  FAIL 3 is today's number for a raw `cp` of the template, not a CI-verified
  property of prod-new's actual output.
