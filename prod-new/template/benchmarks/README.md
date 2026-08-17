# Benchmarks

Comparison is ALWAYS statistical/relative (`tier-policy.yaml`:
`benchmarks.comparison = statistical_relative_only`) — there is no absolute
SLO gate here (`benchmarks.absolute_slo = dedicated_hardware_only`, and
this scaffold has none). `make bench` runs and records; nothing about a
benchmark's raw number blocks a PR.

## Running

```sh
make bench
# or, to compare against the baseline:
go test -run=^$ -bench=. -benchmem -count=10 ./internal/domain/... > new.txt
benchstat benchmarks/baseline-scaffold.txt new.txt
```

## Baseline

`baseline-scaffold.txt` was captured at scaffold time (no git SHA yet —
see the file's own header). Regenerate it (as `baseline-<sha>.txt`) after
the first real commit in a standalone repo, and periodically thereafter as
the service's hot paths change deliberately — never to hide a regression.

## Profiling

`profile.sh` captures a CPU/memory profile pair for a chosen package.
`internal/adapter/in/pprofhttp` serves the LIVE profiling endpoint
(`net/http/pprof`, gated by `PPROF_PORT`, off by default) — the two
together are this dimension's "capture path AND live endpoint" pair
(tier-policy.yaml: `benchmarks.profiling = periodic`).

Profiles captured by `profile.sh` are written to `benchmarks/profiles/`
(gitignored; see that directory's own README) — never committed, since a
profile is a point-in-time artifact, not a regression fixture.
