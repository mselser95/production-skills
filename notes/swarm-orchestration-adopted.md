# Orchestration approach adopted 2026-11-27

Source: ~/dev/personal/swarm-orchestration-2026-11-27/REPORT.md (study of ~80 sources plus a
measurement of this goal's session: 8.56 h, 81 dispatches, mean concurrency 2.87, 41.5% of
agent time in gates, 12 of 16 Opus rounds CHANGES REQUIRED). Relayed by another session of
the owner's; adopted as reversible work (PRs).

1. Plan as a DAG checked by a script (waves, width, critical path; two tasks of one wave may
   not share a file).
2. Dispatch from code; chain implement -> review per task.
3. Agents run a scoped inner check only, 15 s budget (see brief-machine-rules.md).
4. Review per change, in parallel, on the diff; the validator mutates only the added check.
5. One integration train: join reviewed, path-disjoint changes on a temporary branch, run the
   full suite ONCE in the 2-CPU container. Green: land the batch as one PR, one commit per
   task. Red: bisect by halving with a script, eject the culprit, land the rest. Batch size
   starts at 4, +1 per green batch, halved on red.
6. A task others depend on goes through the train before its dependants are batched.
7. When a batch lands, one line to in-flight agents whose paths it touched. No agent chat.
8. Cap by API rate limit, token budget and DAG width, not host CPU.

To prove locally (report section 5): full-suite runs per landed change (< 1.0, from > 5.8);
share of agent time in gate-like Bash (< 10%, from 41.5%); mean concurrency; p and flake rate
per batch; escaped defects on the default branch. Mutation proofs for the train: a planted
failing change is the only one ejected; two changes that pass alone and fail together make
the batch red.

Homes in the skills (after the PoC is proven): _shared/dispatch.md, the change-plan format in
prod-spec, prod-implement's gate step, prod-validator, prod-ops (train + bisection).
