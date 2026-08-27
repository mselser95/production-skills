# Load baseline — placeholder (scaffold commit)

**Status:** placeholder. No load sweep has executed yet — this template has no
standalone git history, no declared peak, and no host worth naming, so every
number below would be an invention. A file of invented capacity numbers is
worse than none: it is the one artifact people quote in a design review.

**The real command** this placeholder stands in for
(`tier-policy.yaml`: `capacity: { margin_target: 2x, measured: required }`):

```sh
make load
# or, with the two facts only a human can supply:
RATES="500 1000 2000 4000 8000" TARGET_RPS=800 LATENCY_BUDGET_MS=50 make load
```

`benchmarks/load/sweep.sh` runs exactly this — it builds `cmd/`, starts the
service on a loopback port with a throwaway data directory, sweeps rising
rates against it with `benchmarks/load/loadgen.go`, and writes the result to
**`benchmarks/load/baseline.md`**, which is the file a real service commits and
this one is the template for. Nothing overwrites the placeholder you are
reading.

## What the artifact must contain, and why each part is not optional

### Offered rate and achieved rate, per rate in the sweep

Two columns, always side by side, because neither means anything alone. While
the service keeps up they are equal; the rate at which they part company is the
whole measurement. A table of achieved rates without the offered rate beside
them cannot be read at all — 4000/s is excellent or a 50% shortfall depending
on a number that is not on the page.

`achieved` counts SERVED (2xx) responses only. A service that sheds load
answers fast and does no work, and counting refusals here would make shedding
indistinguishable from capacity. The refused and failed columns sit beside it
so a run that held its rate by refusing everything reads as exactly that.

### Saturation point

The LOWEST offered rate at which either:

- achieved load stopped tracking offered load (`achieved/offered < 0.99`), or
- p99 breached the declared latency budget.

Recorded with which of the two tripped, because they are different failures
with different fixes — a throughput cliff is usually a resource, a latency
cliff usually a queue.

Two honest outcomes, and both must survive into the file rather than being
rounded into a number:

- **Not reached.** The service kept up at every rate offered. That is a LOWER
  BOUND — "at least the top rate" — and the sweep needs extending. The top row
  is not the capacity. `make load` exits non-zero on this for that reason.
- **No declared budget.** With `LATENCY_BUDGET_MS` unset only the throughput
  half of the definition is evaluated, and the artifact says so: a service can
  breach its latency budget far below its throughput cliff.

### Margin against the declared target

`saturation / TARGET_RPS`, against the **2x** in `tier-policy.yaml`
(`capacity.margin_target`).

`TARGET_RPS` — the rate this service must actually sustain — has NO DEFAULT and
never will. It is a fact about the business, not about the code, and a default
would make this the vacuous form of a capacity gate: a ratio with no
denominator passes every service forever while reading as a measurement. Unset,
the artifact records the margin as `NOT COMPUTABLE` and names the missing
input. Set, and a margin below 2x fails `make load`.

### Toolchain and host

`go version`, OS, architecture, CPU count. A baseline exists to be compared
with the next one, and a saturation rate from an unnamed machine cannot be:
half the "regressions" found this way are a different runner size. This is the
repo's own lesson — the same reason `benchmarks/baseline-scaffold.txt` carries
its provenance in its header.

### Rows the generator spoiled

`loadgen` reports `generator_suspect=true` when it was itself behind schedule
or dropped arrivals it never issued. Such a row measures the load generator,
not the service, and the sweep marks it `UNUSABLE` and refuses to let it set
the saturation point. A run where every row is unusable is a failure, not a
capacity of zero.

## When to regenerate

After the first real commit, and thereafter whenever the service's hot path
changes deliberately — the same cadence `benchmarks/README.md` prescribes for
the microbenchmark baseline, and never to make a regression go away. A sweep
run on a busy laptop will mark most of its rows unusable and that is the
harness working: a baseline worth quoting comes from a quiet host, with the
generator ideally not sharing it with the service.
