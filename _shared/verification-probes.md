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
