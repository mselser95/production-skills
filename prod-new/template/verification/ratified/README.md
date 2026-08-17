# verification/ratified — the trusted set

Human-ratified invariants as executable tests. Not agent-writable: changes
go through the ratification flow (candidates live in `.prod/ratify-queue/`).
These tests carry the T0 rule — a nondeterministic failure here is an
incident, never a quarantine (`tier-policy.yaml`: `invariant_flake_rule`).

Every test in `invariants_test.go` carries a `NON-VACUITY EVIDENCE` header
naming the exact code mutation that was applied, observed to turn the test
RED, and reverted before commit — never asserted from theory. Rerun the
cited mutation whenever the line it names moves.
