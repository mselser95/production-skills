# verification/conformance — capability class conformance kits

## The contract

`production.yaml` declares this repo's capabilities and, for each, the
**class** it belongs to (`external_effect`, `source_of_truth`,
`event_consumer`, `event_producer`, `external_read`, `connection`,
`signer`). `tier-policy.yaml` (`capability_classes`) defines what a class
demands: a fixed scenario checklist and a set of declared obligations. This
package turns that checklist into one mechanical, reusable Go function per
class — a **kit** — so "this adapter satisfies its port contract" is a test
result, not a comment someone has to keep honest by hand.

Two rules follow directly from that:

1. **A new adapter for an existing class must pass its kit.** Add a second
   `external_effect` adapter and its own test file calls
   `conformance.ExternalEffectKit` exactly like
   `internal/adapter/out/store` does. You do not get to invent a smaller
   checklist for the new adapter — the class's checklist is the class's
   checklist, regardless of which adapter is proving it.
2. **Adding a scenario to a class is a policy change, not a test change.**
   The scenario lists in `kit.go` are a direct transcription of
   `tier-policy.yaml`'s `capability_classes.*.scenarios`. They change when
   that file changes, ratified at the org level — never as a local edit to
   make one adapter's kit pass or fail.

## What "passing the kit" means

Each `XxxKit(t, drive)` function runs the class's whole scenario checklist
as subtests, calling `drive(t, scenario)` once per scenario. The adapter's
own `conformance_kit_test.go` supplies `drive`: for every scenario it must
either

- **exercise the real adapter through its public port** and assert the
  class's declared obligations hold, or
- **call `t.Skip` with an explicit, documented reason** when the scenario
  genuinely does not apply to that adapter.

A silent pass — a case that neither asserts nor skips — is exactly the
gameable checklist this package exists to prevent, and `scenarioKit` fails
loudly (`t.Fatalf`) if it is ever handed an empty scenario list, so a
class's checklist cannot quietly go vacuous either.

## This template's wired example

`internal/adapter/out/store` (the outbox) is wired to `ExternalEffectKit` —
see `internal/adapter/out/store/conformance_kit_test.go`. It is the ONE
capability this greenfield scaffold declares, so it is the only kit with a
live adapter behind it today. The other six kits (`connection`,
`event_consumer`, `event_producer`, `external_read`, `source_of_truth`,
`signer`) exist and are exercised by `TestConformanceKits_RejectAnEmptyScenarioList`
in `kit_test.go` (proving the machinery itself is real, not dead code) —
the next real capability this service grows plugs into whichever kit its
declared class demands, exactly the way `store` already does.

## Provenance

Every kit-invoking test carries:

```go
// provenance: derived
// verifies: capability <id> / <class> conformance kit (tier-policy: conformance kits GATE at T0)
```

`derived` because the obligation being checked — "this capability's class
kit passes" — is a direct, mechanical consequence of `production.yaml`'s
capability declaration plus `tier-policy.yaml`'s scenario checklist, not a
value pinned without a ratified property behind it.
