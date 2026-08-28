# Load and chaos experiments — the procedure

The procedure for building a load or chaos experiment against a service or a
system. It exists so that "build the load/chaos experiments for X" produces the
same thing every time, and so that what it produces can fail.

Derived from the 34 demos in `demos/INDEX.md`. Every mandatory control below is
here because its absence produced a green, false result in one of them — these
are scars, not best practices.

## The rule everything else enforces

**A load or chaos experiment that cannot fail is not an experiment. It is a
demonstration that the system was working when you looked at it.**

Each step carries a "not ready if" condition. When the answer is "I don't
know", that step is NOT done and the next one does not start.

## The two questions are different

Conflating them produces experiments that answer neither:

| | Load | Chaos |
|---|---|---|
| **Question** | where does it stop keeping up? | does it come back on its own? |
| **Variable** | the arrival rate | the injected fault |
| **Output** | a measured saturation point, with its margin | a recovery bound, or its absence |
| **Fails if** | you never saturated (the number is a lower bound) | the injected fault did not move the metric |
| **Dimension** | §25 | §13, §20, §26 |

Their intersection has a name — **metastability** — and it is chaos UNDER load,
the only experiment whose interesting property appears AFTER the trigger is
removed. That is step 7.

## The procedure

### 1. Declare the steady state, before writing anything

One metric, one threshold, one window, and **the vantage point it is measured
from**. Written before the experiment, in a file, not in somebody's head.

The vantage is not a detail. A metric the service emits about its own health
runs in the same process, on the same host, over the same devices — and goes
quiet in exactly the failure it exists for. A steady state measured from inside
cannot see the class of failure that matters most.

**Not ready if** you cannot write the predicate as an expression returning true
or false.

### 2. Calibrate the detector before the subject

Run the harness against the healthy system and show it reports clean, **with
counts**. Then plant a known anomaly and show it is found. Only then is a later
"nothing found" evidence rather than silence.

This is the most-skipped step and the most expensive one. A consistency checker
run only against a healthy single node finds zero anomalies, and that zero reads
as a property of the system when it is a property of the experiment.

**Not ready if** the detector has never found anything, including something you
planted yourself.

### 3. Load: generate open-loop, measure from the scheduled arrival

Arrivals are scheduled against the wall clock, independent of whether earlier
responses returned. Latency is measured from the **scheduled instant**, never
from the send.

A closed-loop harness — N workers, each sending its next request when the
previous returns — cannot offer load faster than the system accepts it. When the
system stalls the harness stalls with it: the requests that WOULD have been slow
are never issued, so the percentile is computed over exactly the requests the
system was willing to take.

Measured in `coordinated-omission-demo`, same service and same stall: p99 of
**14.6 ms** closed-loop against **3859 ms** open-loop, and the service counted
the 1594 arrivals the closed harness never issued.

**Not ready if** the generator can run out of sockets or CPU before the system
does. Measure your own schedule lag and compare it against the effect you intend
to observe.

### 4. Load: sweep until saturation, and prove you saturated

A single rate is not a load experiment. Sweep, and read saturation from the
**gap between offered and achieved** — not from the percentile, which degrades
smoothly and flatters.

The output is a measured saturation point and a margin against the expected
peak. If the sweep never saturated, the number is a LOWER BOUND and the artifact
must say so.

**Not ready if** you cannot name the rate at which offered and achieved parted.

### 5. Chaos: choose faults by capability class, not from a catalogue

The faults worth injecting derive from what the service IS, and that list
already exists: the `scenarios` of its capability class in `tier-policy.yaml`.
An `external_effect` owes `timeout_after_acceptance`, `duplicate_response`,
`retry_storm`; a `connection` owes `thundering_herd_reconnect`; a
`source_of_truth` owes `serialization_conflict` and `restore_from_backup`.

One warning that cost a whole demo: **the clean symmetric partition is the one
everybody tests and almost never the one that breaks things.** Real ones are
partial and asymmetric — A reaches B while B does not reach A. That is three
distinct shapes, not one (`asymmetric-partition-demo`).

**Not ready if** the fault list came from your intuition instead of the class
checklist.

### 6. Chaos: blast radius, abort path, and rehearse the abort

The radius is declared up front (one namespace, N% of replicas). The abort fires
when step 1's predicate is violated, and it is proven **by invoking it**, not by
describing it.

An abort path nobody exercised fails when called — a wrong label selector is the
realistic version — and the experiment runs on past its own abort. That is
precisely the difference between `required` and `required_and_rehearsed`.

**Not ready if** you have never watched the abort fire.

### 7. The intersection: remove the trigger and keep watching

The step almost nobody performs, and where the most expensive failure lives.
Inject under load, let it collapse, then **remove the injection** — and keep
measuring.

A metastable system does not come back. Its own retry load became the trigger,
so it stays collapsed over a cause that no longer exists. Measured in
`retry-storm-demo`: the naive variant was still at **0/s twenty seconds after**
the trigger was removed, putting 599/s on its dependency with 86% of that work
completed for nobody. With a global retry budget it returns in 1s.

**Not ready if** you stopped measuring when you stopped injecting.

### 8. Ask which mechanism acted

Two different causes produce the same client-visible symptom, and the temptation
is to credit the mechanism you were testing.

A lease expiry and the engine's own `VALID UNTIL` both yield "password
authentication failed". A partition and a restarted pod both yield stale reads.
The answer is not inferred — the system is ASKED (query `pg_roles`, read the
`member_id` in each response header, compare pod UIDs) and alternatives are
excluded **by observation**. `partition-consistency-demo` excludes six.

**Not ready if** your conclusion survives equally well in a world where the
mechanism you tested does not exist.

### 9. The deliverable: an artifact that can go stale, a control that can fail

Load produces `benchmarks/load/baseline.md`: offered and achieved rate,
saturation point, margin against the declared peak, and **the toolchain and
host** — a measurement without its environment cannot be compared with the next
one. With its date INSIDE the document, never the mtime: a clone stamps every
file with the checkout time, so an mtime freshness check reports a three-year-old
baseline as zero days old, fail-open, on exactly the machine that gates the merge.

Chaos produces the versioned experiment plus the observed recovery bound. Both
enter the `regressions/` corpus.

**Not ready if** you have not written the control that makes the experiment fail
on purpose.

## The mandatory controls

Each executed, each exiting non-zero. Not optional and not decoration — every
one exists because its absence produced a false green in one of the 34 demos.

| Control | What it proves | Applies to |
|---|---|---|
| **No fault** | the same harness, same checker, healthy system: finds zero — and the experiment NAMES ITSELF the vacuous form, because it is the run most people actually perform | both |
| **Blind detector** | mutate one token of the checker over identical data: if the verdict does not move, the checker was not looking | both |
| **Fault not applied** | the rule was applied and the effect did not occur: verify the partition FROM INSIDE the pod, never from `iptables`' exit code | chaos |
| **Closed harness** | the same sweep closed-loop produces a flattering, wrong curve | load |
| **Insufficient effect** | if the injection did not move the metric past the noise, nothing was proven: fail loudly rather than report a delta | both |
| **Unrehearsed abort** | invoke it with a broken selector and watch the experiment continue past its own abort | chaos |

## When the subject is a system, not a service

Three things change, and only three:

- **The steady state is end to end.** A metric per service gives six green
  dashboards and a user who cannot buy. The predicate is measured at the edge
  where somebody perceives the result.
- **The fault is injected into the LINK, not the node.** What breaks systems is
  the path: latency between A and B, an asymmetric partition, the dependency
  that answers SLOWLY instead of failing — which is worse, because no error trips
  a breaker and every caller's connections stay held.
- **The effect is counted at the sink.** Duplicates injected at every hop of a
  three-service chain must produce exactly one effect, and the counter is the
  FINAL destination. A count kept by the producer is a claim by the interested
  party (`dedup-end-to-end-demo`).

## What the request produces

On "build the e2e / load / chaos for X":

1. **Read X's capability class** (`production.yaml`) and derive the mandatory
   faults from it. If the repo has no spec, that is the first finding and it is
   reported before any harness is written.
2. **Ask ONE thing that cannot be derived**: the steady state and its vantage
   point. Everything else derives.
3. **Deliver**, in the service's repo or its own:
   - `benchmarks/load/` — open-loop generator, sweep, `baseline.md`
   - `chaos/` — the experiment with its hypothesis, radius and abort
   - `scripts/tests/` — the selftest proving the checker can fail
   - `run-experiment.sh` — idempotent, with a teardown that COUNTS
4. **Run both directions** and hand over the real output: the green path and
   every control exiting non-zero.
5. **State what was NOT proven.** There is always something, and that section is
   what makes the rest credible.

## Provenance

The demos that most shaped this: `coordinated-omission` (step 3), `usl-fit`
(step 4), `asymmetric-partition` (step 5), `chaos-steady-state` (step 6),
`retry-storm` (step 7), `partition-consistency` (steps 2 and 8). All public,
each with a `run-demo.sh` that exits 0 and controls that do not.
