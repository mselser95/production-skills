# Deferred: five wiring-probing rows for verify-standard.sh

Proposed 2026-08-27 by the crash-only/error-handling task of the papers
roadmap, DEFERRED rather than landed, and the reason is a name collision, not
a quality judgment: its `error-handling-fitness` row (which probes check-fast's
own recipe for the wiring) shares a row name with the one the probe-rows task
landed the same day (which executes the script and reports its verdict).
Landing both breaks the probe; reconciling them means re-verifying merged
logic on a 135KB TCB script, which deserves its own change with its own
selftest pass rather than a tail-end merge.

What the deferred rows add that the landed ones do not: they probe the WIRING
(`check-fast`'s recipe invokes the gate) instead of only the gate's verdict —
the distinction the fragment's own header documents with a measured miss.
The fragment was executed and mutation-tested by its author against an
instantiated template copy (five rows, five mutations, two first-pass repairs
recorded in its comments).

To land: merge each deferred row's wiring check INTO the same-named landed row
(one row per name), extend `_shared/probes/load-rows-selftest.sh` with the
wiring mutations, and run the selftest to green plus one deliberate red.
