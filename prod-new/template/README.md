# <SERVICE>

A repo born at the production-verifiability standard. `<OWNER>`/`<SERVICE>`
are slots `prod-new` substitutes at scaffold time — everything else here is
real, working code, not a TODO.

## The example domain

An append-only **units ledger**: deposit and withdraw, event-sourced. Small
enough to read in one sitting, real enough to carry genuine invariants
(conservation, idempotency) rather than asserting nothing. Replace this
domain with your service's own the moment you start — the three zones below
are what stays.

## The three zones

```
internal/domain      pure decision core -- no I/O, no clock, no random, no
                      goroutines, no internal imports (enforced mechanically
                      by internal/architecture/boundaries_test.go)
                      State, Event, Apply(state, event) -> (state, effects)
                      decimal-string money math (internal/domain/money.go)

internal/app          durable orchestration -- injected clock/id ports
                      (declared locally, never importing internal/platform
                      or internal/adapter -- see ledger.go's doc), a command
                      state machine with documented recovery semantics per
                      transition, runtime invariant counters

internal/adapter/{in,out}   the shell -- HTTP health/metrics/pprof (in),
internal/platform           the outbox-pattern external-effect adapter and
                             durable event log (out/platform); clock, ids,
                             config, observability and buildinfo ports live
                             in platform with real + deterministic-fake
                             implementations

cmd/<SERVICE>          composition root ONLY -- wires everything above,
                        injects the real clock/ids/tracer, starts the HTTP
                        servers. No business logic lives here.
```

## The one command to add a feature

```
prod-spec
```

Run it against this repo before writing any code for a new task. It reads
`production.yaml`, maps your intent to an existing or new capability, pulls
every ratified invariant, and derives the obligations your change owes —
producing a resolved context and change plan that `prod-implement` then
executes one bounded task at a time. See `AGENTS.md` for the full pipeline
and the hard rules every agent in this repo follows.

## Gates

| command | what it runs |
|---|---|
| `make check-fast` | build, vet, plain test, architecture — seconds, the cheap presubmit gate |
| `make verify` | lint, architecture, race, coverage, chaos, e2e, fuzz — the full presubmit |
| `make verify-standard` | the standard's own probe (`scripts/verify-standard.sh`) — must report zero FAIL |
| `make test-advisory` | the candidate-provenance lane (`-tags=candidate`) — never blocks |
| `make check-registries` | liability-registry expiry gate |
| `make bench` | benchmarks — recording only, never a gate |
| `make sim` | stage-1 deterministic simulation (`verification/simulation`) — fixed seed by default, `SIM_SEED=<n>` to sweep; the sweep is advisory |

## What this template does NOT ship

A real deployment pipeline (progressive delivery, canary analysis,
rollback automation) is deliberately out of scope for a template — it is
an infra/platform decision each org makes once, not something a service
scaffold should invent. `docs/SLO.md` documents this as a proposed,
unratified gap rather than pretending it away.

## Verified module path (read this if you are `prod-new` substituting slots)

This template was developed and every gate verified under the temporary
module path `github.com/<OWNER>/<SERVICE>` — Go cannot build a module whose path
contains literal `<OWNER>`/`<SERVICE>` slots, so that substitution is
deliberately the LAST scaffolding step, never the first:

1. Copy `template/` into the new repo.
2. Replace every literal `<OWNER>` and `<SERVICE>` occurrence (`go.mod`,
   every `github.com/<OWNER>/<SERVICE>/...` import, `internal/architecture/
   boundaries_test.go`'s `modulePath` constant, `docker/Dockerfile`'s
   `-ldflags -X` paths, `CODEOWNERS`, `production.yaml`, `AGENTS.md`, this
   file) with the real values, and rename `cmd/<SERVICE>` to `cmd/<SERVICE>`.
3. `git init` (or push into the real remote) so the operational-determinism
   tests that need a real `.git` directory (`TestBuiltBinary_
   CarriesANonEmptyVCSRevision` in `internal/platform/buildinfo`) stop
   legitimately skipping and start asserting for real.
4. Immediately re-run every gate against the substituted path: `go build
   ./...`, `go vet ./...`, `go test ./... -race -count=1`, `make
   check-fast`, `make verify`, `make verify-standard`. All must be green
   before handing the repo to a human — a scaffold that ships red teaches
   that red is normal.
