# Runbook

Every gate in this repo prints its own next step, so this file deliberately does
**not** repeat them. It holds the things a failure message cannot tell you.

## The gate is `make verify`. It is not `scripts/verify-standard.sh`.

`_shared/probes/verify-standard.sh` implements the **Go** toolchain and refuses
to run here (`detected 'unknown'`, exit 2). This repo is shell and markdown. That
refusal is correct and it is not a gap to close by vendoring the probe in — a
vendored probe that refuses to run is a gate the repo believes it has and does
not. It is edited here and executed in scaffolded repos.

| command | what it answers | ~time |
|---|---|---|
| `make check-fast` | what the pre-commit hook runs | 10s |
| `make verify` | check-fast + every selftest + TCB | 25s |
| `make evidence` | all nine gates, written to `.prod/evidence/` | 25s |

## `install.sh --verify` has three exit codes and they mean different work

| code | meaning | what to do |
|---|---|---|
| 1 | **TCB DRIFT** — installed contents differ from the manifest | Read the named files before reinstalling. This is the tamper signal. |
| 2 | **STALE INSTALL** — manifest intact, describes an OLDER source | You edited a skill and did not reinstall. `./install.sh`. Harmless and common. |
| 3 | **TCB WRITABLE** — contents right, read-only guard missing | An install interrupted between the manifest write and the chmod. `./install.sh`. |

Exit 2 is the one you will actually hit, and it is why a session can be running
an older probe than the one in your editor.

## Adding a probe

Put it in `_shared/probes/`, then **wire it into the `Makefile`**. If you do not,
`probe-wiring.sh` fails the commit — deliberately, because a gate nothing invokes
is a document that looks like a gate. Three things it will tell you about:

- naming it only in a **comment** does not count;
- a probe covered by an existing **glob** (`$(PROBES)/*-selftest.sh`) counts;
- a probe that legitimately should not run here needs a **declared exception**
  with its reason, keyed by path, and a stale one is an error.

Give it a `*-selftest.sh` next to it. `make selftests` globs them, so it needs no
registration anywhere — and CI runs `make selftests` for exactly that reason.

## Two config dirs, and both must be installed

`~/.claude-clc` and `~/.claude` each carry their own copy and manifest. Installing
into one leaves the other stale, and the stale one is whichever you are not
looking at. Reinstall both:

```
for c in ~/.claude-clc ~/.claude; do CLAUDE_CONFIG_DIR="$c" ./install.sh; done
```

## The evidence record is not in git

`.prod/evidence/*.json` is gitignored. The durable record is the CI artifact
(`evidence-<sha>`), whose provenance is the run. `.prod/evidence/README.md`
explains why, including what the filename means — `<sha>.json` is an attestation,
`dirty-<sha>-<ts>.json` explicitly is not.

## What is NOT enforced

**The forge requires no status check on `master`.** Measured: `branch protection`
returns 404 and both rulesets endpoints return `[]`. "Blocking" here means the
workflow goes red and a human reads it, not that the forge refuses the push.
That is a consequence of the direct-push-to-master workflow, not an oversight —
required status checks and direct pushes are mutually exclusive. Changing it is
the owner's decision; see `.prod/gap-report.md`.

## Three invariants are proposed, none ratified

`.prod/ratify-queue/*.yaml`, all `PENDING-HUMAN`. `verification/ratified/` is
empty by design: bootstrap never writes it, because "what must never happen" is
the one thing an inventory cannot infer. Each package carries a
`non_vacuity_check` whose mutation was run, not written.
