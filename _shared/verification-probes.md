# Verification probes — verify the EFFECT, never the report

An agent's `IMPLEMENTED` block is a claim. A dimension is done when a command
you ran yourself proves the effect exists in the running system. This file
exists because the orchestrator repeatedly relayed claims as facts and shipped
two half-features (a tracing port nobody wired into the binaries, and a
profiling section that documented nothing) — both caught by the human, not by
the process.

**The rule: no dimension is reported as done until its probe has been executed
and its output read. The report is the probe output, not a summary of it.**
`probes/verify-standard.sh` implements this; run it before every completion
claim.

## The anti-patterns, named

| Artifact exists | ...but the effect may not |
|---|---|
| a tracing port + span calls | nothing injects a real tracer → every span is a no-op in production |
| a `govulncheck` CI job | the scan was never run → it may be red on day one (it was: 6 called CVEs) |
| a metrics manifest | nothing compares it to what `/metrics` actually emits → documentation drift |
| an invariant test file | it may pass on broken code → never proven to fail under a mutation |
| a fuzz target | it may not be reachable/runnable → never executed for real |
| a benchmark file | no baseline recorded → nothing to compare against |
| a "profiling documented" line | grep finds zero pprof references → the claim is false |
| a coverage floor file | measured on a different tree → stale, not enforced |
| a runbook | cites metrics/env vars that do not exist → useless at 3am |

## Probe design rules

1. **Probe the wiring, not the definition.** For anything injectable (tracer,
   clock, logger), the probe greps the ENTRYPOINTS (`cmd/**`), not the port.
2. **Run the tool, don't check for its config.** Security, fuzz, benchmarks,
   coverage: execute and read the exit code and the numbers.
3. **Prove non-vacuity where it is cheap.** An invariant/regression test must
   be shown red under a deliberate mutation at least once; record which.
4. **Cross-check documents against reality.** Every metric name, env var and
   command cited in ops docs must resolve against the code.
5. **`N/A` is a legal probe result** only when the spec's `out_of_scope`
   carries the ratified reason — the probe reads the spec, so a silent
   omission cannot masquerade as N/A.
6. **A failing probe is a finding, not a reason to soften the probe.**
7. **Every FAIL must name the defect.** A verdict with empty evidence is worse
   than no row at all: it points at nothing, so the only available "fix" is to
   weaken the check. When a gate can fail several ways, give each one its own
   branch and its own evidence string — and give "the gate did not complete"
   a branch too, because an unproven gate is not a clean one. This rule exists
   because three rows in `verify-standard.sh` shipped without it: govulncheck
   producing no verdict, `coverage FAIL "0 floor violation(s):"` whenever the
   failure was anything but a floor, and a real-lane row that blamed the lane
   for a failure elsewhere in the repo.

## Known-unreliable inputs

**Go's test cache could decide a coverage verdict — FIXED 2026-08-19.**
`scripts/coverage.sh` reads whatever `go test` returns, and `go test` will serve
a CACHED coverage profile. A profile cached from a degraded run therefore gated
a tree it was never measured against: on 2026-08-18 the same commit reported
`pprofhttp 64.71%, below its floor of 80.00%` in one working copy and `85.6%,
all packages at/above their floor` in another, with the only difference being
cache state — `go clean -testcache` made it deterministic.

The fix is `-count=1` on every `go test` invocation that a gate reads, which
tells the toolchain to run rather than to recall. It is now on `coverage.sh`
(the one that decides a verdict) and on `test`, `race`, `architecture`,
`test-advisory` and `e2e` in the Makefile. It is deliberately NOT on the
`-list` and `-fuzz` invocations, which do not consume cached results.

Verified on a real repo: cold cache, warm cache and a third run all report the
same total with every package floor green — the point being that they AGREE,
not the number itself.

Two things worth keeping from how this was found. It was reported by one agent
and NOT reproducible by another, which is exactly the shape a report gets
dismissed for; it was real anyway. And the mechanism never had to be fully
understood to be closed — "a gate must not be able to read a cache" is a
property worth enforcing whether or not you can explain the day it bit.

The operational rule still stands for any gate that has not been converted: a
coverage FAIL that disappears after `go clean -testcache` is a cache artifact,
not a finding about the code, and it is never answered by lowering a floor.
