# Candidate invariants — pending human ratification

Properties this service believes hold, exercises continuously, and has NOT had
ratified by a human. They are listed in `production.yaml` under
`invariants_pending_ratification:`, which `scripts/verify-standard.sh` counts
and reports separately from the ratified set.

They live here rather than in `.prod/ratify-queue/` deliberately. The probe
treats every file in the ratify-queue as backing a RATIFIED invariant: it
applies that package's `non_vacuity_check` and runs `expect_red` scoped to
`verification/ratified/`. A candidate whose evidence is a property test in
`internal/domain` cannot satisfy that scoping — the scoped run finds no such
test, prints `ok [no tests to run]`, and the probe reads that as
STAYED-GREEN, i.e. a vacuous invariant, i.e. a FAIL. Forcing one in would mean
either moving an unratified test into the trusted set or writing a check the
probe reports as decayed. Neither is honest.

So candidates wait here with their evidence until a human ratifies them. On
ratification: the test moves to `verification/ratified/`, the package moves to
`.prod/ratify-queue/` and gains a real `non_vacuity_check`, and the spec's
`invariants:` list grows by one.

Promotion is a human act. Nothing in this directory gates the build.

This directory ships with no packages because the scaffold's two example
invariants are both ratified. That is the normal starting state, not an
omission.
