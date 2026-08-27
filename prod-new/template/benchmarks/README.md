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

## Load, and why it is not a slower benchmark

`load/` is a different question, not a longer version of this one. A benchmark
measures ONE operation in isolation, in process, with no arrivals and no
queue — it answers "how long does this take" and is structurally unable to
answer "what happens when they arrive faster than that". Where throughput
stops tracking offered load, whether the tail collapses before that point, and
whether anything grows without bound all live in the gap between the two.

```sh
make load    # sweep rising rates, write benchmarks/load/baseline.md
make soak    # hold a rate for SOAK_MINUTES (default 30), fail on resource growth
```

- `load/loadgen.go` is the generator. OPEN-LOOP: arrivals are scheduled off the
  wall clock and never wait on a response, and latency is timed from the
  SCHEDULED arrival. A closed-loop driver backs off exactly when the system
  slows, so it reports the system's own pace as its capacity and drops the
  requests that would have been slow (coordinated omission — Gil Tene, "How
  NOT to Measure Latency", 2015). Its header names the four ways to ship a
  load harness that runs and measures nothing.
- `load/sweep.sh` (`make load`) finds the saturation point and writes the
  baseline. `load/baseline-TEMPLATE.md` is the format and what each part is
  for; the scaffold ships only that placeholder, because a capacity number
  invented at scaffold time is the one artifact people quote in a review.
- `load/soak.sh` (`make soak`) and `load/growth-check.sh` are the leak lane.
  The verdict is a separate script reading a sample table on stdin, so "does
  this detector actually go red on a leak" is answerable in a second against a
  synthetic series rather than only by leaking for half an hour.

Unlike the benchmarks above, these two are GATES: `make load` exits non-zero
when it produced no usable capacity number, and `make soak` when a resource
grew and did not level off. Neither is in `make verify` — both start a real
process and run for minutes — so CI runs them in the nightly lane.

Expect `generator_suspect=true` rows on a developer machine, particularly at
low rates where the tail is small enough for a few milliseconds of scheduling
to dominate it. That is the harness being honest about itself, not failing: a
baseline worth committing comes from a quiet host, ideally one not also running
the service.

## Profiling

`profile.sh` captures a CPU/memory profile pair for a chosen package.
`internal/adapter/in/pprofhttp` serves the LIVE profiling endpoint
(`net/http/pprof`, gated by `PPROF_PORT`, off by default) — the two
together are this dimension's "capture path AND live endpoint" pair
(tier-policy.yaml: `benchmarks.profiling = periodic`).

Profiles captured by `profile.sh` are written to `benchmarks/profiles/`
(gitignored; see that directory's own README) — never committed, since a
profile is a point-in-time artifact, not a regression fixture.
