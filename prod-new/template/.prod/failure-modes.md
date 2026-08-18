# Failure-mode matrix

Denominator: `tier-policy.yaml`'s `capability_classes` scenario checklists,
for every class this repo's `production.yaml` declares a capability of.
Never authored by hand from scratch — each row cites the test that proves
it (`tested`) or the documented reason it does not apply (`N/A`). Zero rows
may read `blocked` (a `blocked` entry means a required production change is
outstanding — `scripts/verify-standard.sh`'s scenario-matrix probe fails the
build on any).

## `external_effect` — capability `units_notification` (`internal/adapter/out/store`)

| scenario | status | evidence |
|---|---|---|
| rejected | N/A | `driveExternalEffect` in `conformance_kit_test.go`: rejection happens upstream in `domain.Apply`, before this adapter ever receives an effect to journal |
| timeout_before_acceptance | tested | `driveTimeoutBeforeAcceptance` |
| timeout_after_acceptance | tested | `driveAckLostRetriedWithSameKey` |
| duplicate_response | tested | `driveAckLostRetriedWithSameKey` |
| malformed_response | tested | `driveMalformedResponseExhaustsAttempts` |
| unavailable | tested | `driveUnavailableThenReconciles` |
| extreme_latency | tested | `driveExtremeLatencyRespectsContext` |
| crash_between_decision_and_effect | tested | `driveCrashBetweenJournalAndPublish` |
| retry_on_unknown_state | tested | `driveAckLostRetriedWithSameKey` |

## `source_of_truth` — capability `units_ledger` (`internal/app`)

| scenario | status | evidence |
|---|---|---|
| deadlock | N/A | `driveSourceOfTruth` in `internal/app/conformance_kit_test.go`: single mutex, no nested lock acquisition |
| serialization_conflict | tested | `driveSerializationConflict` — 500 concurrent deposits under `-race` |
| timeout | N/A | no I/O happens while the mutex is held |
| commit_ok_response_lost | N/A | in-process call, no separate ack channel |
| connection_dies_before_commit | N/A | no client/server connection; durability is `internal/platform/eventlog`'s own, separately covered, concern |
| connection_dies_after_commit | N/A | same as above |
| restore_from_backup | N/A | recovery is full-log replay, not point-in-time backup restore — see `production.yaml`'s `backup_restore_test` decline |

## `external_read` — capability `health_metrics_surface` (`internal/adapter/in/healthhttp`)

| scenario | status | evidence |
|---|---|---|
| stale_data | tested | `driveExternalRead` in `conformance_kit_test.go`: `TestReadinessAt_RecentViolationGatesReadiness_ThenClearsAfterCooldown` pattern |
| gap | N/A | point-in-time state, no sequence-number space |
| malformed_response | N/A | this handler renders its own response; not a client of an untrusted upstream |
| unavailable | tested | log-not-configured -> not-ready |
| slow_response | N/A | every read is an in-memory field access, no external round trip |

## Totals

tested = 11, N/A = 10, blocked = 0.

## Status vocabulary, and one constraint on this file

Every scenario row carries exactly one status: `tested`, `N/A` (with the
reason on the row), or `blocked`. `scripts/verify-standard.sh` counts them by
matching a whole status CELL, and **any row whose status cell is `blocked`
fails the build** — that is the point: a blocked scenario is one that needs a
production change before it can be tested, and it should stop the line rather
than sit in a document.

The constraint that follows: do not add a summary or totals table whose rows
put a status word in a cell of its own (`| blocked | 0 |`). The counter cannot
tell that row apart from a real scenario row and will fail the build while
reporting the absence of blocked scenarios. Put totals in prose, or in a row
whose first cell names the metric (`| blocked scenarios | 0 |` is fine — the
status word is not alone in its cell).
