#!/usr/bin/env bash
# load-rows-selftest.sh -- the verdict matrix for the three rows verify-standard.sh
# gained with dimensions 25 and 27: `load-baseline`, `error-handling-fitness`
# and `simulation-advisory`.
#
# WHY THIS FILE EXISTS. Two of those three rows are the shape this framework is
# most often wrong about. `load-baseline` scores a PROSE ARTIFACT, which is the
# easiest thing here to satisfy with a sentence -- the exact failure of
# `grep -qi "reconcil"`, of the `mutation` keyword search, and of
# `grep -rqi "sbom\|syft"`, all three of which shipped green over nothing. And
# `simulation-advisory` carries a promise that it CANNOT FAIL, which is not a
# property anyone can read off the source: `row` silently converts a PASS with
# empty evidence into a FAIL, so an evidence string that goes empty on some
# input would give that row a failing branch it is not supposed to have. A
# promise like that has to be executed to be believed.
#
# HOW IT TESTS. It lifts the probe's OWN functions out of verify-standard.sh --
# including `row` itself, so the empty-evidence guard is in the path -- and
# drives them against scratch fixture directories, one per case. It never greps
# the probe's source for a branch: a grep cannot tell a branch that works from a
# branch that is dead, or from a branch that is the only outcome. That is the
# same reason non-vacuity-selftest.sh sources classify_mutation_result instead
# of restating it, and it is recorded there as a defect that had to be fixed
# after the fact.
#
# EVERY VERDICT EACH ROW CAN PRODUCE IS DEMONSTRATED, not just the happy one.
# `load-baseline` has two distinct NA paths (ratified decline; a spec that
# predates the dimension) and eleven distinct FAILs, and they are separated on
# purpose: an NA that reads like a pass is how a dimension quietly leaves the
# standard, and a FAIL whose message sends the reader to the wrong file is how
# a correct red gets argued away.
#
# Usage: bash load-rows-selftest.sh
# Exit:  0 every case behaved; 1 a case did not; 2 the probe could not be read.
set -uo pipefail

# The probe sits in ONE of two places depending on which layout this file is
# running in, and both are real:
#
#   shared: _shared/probes/load-rows-selftest.sh -> _shared/probes/verify-standard.sh
#   repos:  scripts/tests/load-rows-selftest.sh  -> scripts/verify-standard.sh
#
# Both are tried, rather than assuming a repo root. sbom-ordering-selftest.sh
# resolves its probe as `<repo-root>/scripts/verify-standard.sh`, which is
# correct in a vendored repo and unreachable in production-skills itself, where
# no scripts/ directory exists -- so that file can only ever run in one of the
# two homes it is mirrored into. Nothing is wrong with it there; this one is
# simply written to run in both.
_here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROBE=""
for _cand in "$_here/verify-standard.sh" "$_here/../verify-standard.sh"; do
  [[ -r "$_cand" ]] && { PROBE="$_cand"; break; }
done
[[ -n "$PROBE" ]] || { echo "load-rows selftest: cannot find verify-standard.sh next to or above $_here" >&2; exit 2; }

# --- lift the code under test OUT of the probe -------------------------------
#
# A SELFTEST THAT COULD NOT LOAD ITS SUBJECT MUST NOT LOOK LIKE ONE THAT
# PASSED. Every extraction below is checked, because a renamed or reshaped
# function would otherwise leave the name undefined, every case would report
# the same error string, and a `check` comparing that error against an expected
# substring would simply fail -- but an extraction that yields an EMPTY
# function body defines nothing and fails silently. Refuse loudly instead; this
# is the failure mode sbom-ordering-selftest.sh records for its own marker.
eval "$(sed -n "/^SPEC_AWK_LIB='/,/^'\$/p" "$PROBE")"
[[ -n "${SPEC_AWK_LIB:-}" ]] || { echo "load-rows selftest: could not lift SPEC_AWK_LIB from $PROBE" >&2; exit 2; }

# The scalars the rows read. Lifted rather than restated for the reason the
# functions are: a restated LOAD_MAX_AGE_DAYS would let the probe's window move
# while this file went on certifying the old one.
eval "$(grep -m1 -E '^SPEC=' "$PROBE")"
eval "$(grep -m1 -E '^LOAD_BASELINE=' "$PROBE")"
eval "$(grep -m1 -E '^LOAD_MAX_AGE_DAYS=' "$PROBE")"
eval "$(grep -m1 -E '^EHF=' "$PROBE")"
for _v in SPEC LOAD_BASELINE LOAD_MAX_AGE_DAYS EHF; do
  [[ -n "${!_v:-}" ]] || { echo "load-rows selftest: could not lift $_v from $PROBE" >&2; exit 2; }
done
[[ "$LOAD_MAX_AGE_DAYS" =~ ^[0-9]+$ ]] || { echo "load-rows selftest: LOAD_MAX_AGE_DAYS lifted as '$LOAD_MAX_AGE_DAYS', not a number" >&2; exit 2; }

for _fn in row declined placeholder_value spec_field \
           load_field load_margin_norm load_age_days \
           load_baseline_row error_handling_fitness_row simulation_advisory_row; do
  _src="$(sed -n "/^${_fn}() {/,/^}/p" "$PROBE")"
  if [[ -z "$_src" ]] || ! eval "$_src" || ! declare -F "$_fn" >/dev/null; then
    echo "load-rows selftest: could not lift $_fn from $PROBE -- it was renamed or reshaped" >&2
    exit 2
  fi
done

# `row` writes into these. They are the probe's top-level state, re-initialised
# per case by verdict() below.
declare -a ROWS=(); fails=0; passes=0; nas=0

BASE="$PWD"
_tmproot="$(mktemp -d "${TMPDIR:-/tmp}/load-rows-selftest.XXXXXX")"
trap 'cd "$BASE" 2>/dev/null; rm -rf "$_tmproot"' EXIT INT TERM

cases=0; bad=0
FIXTURE=""
ROW_NAME=""

# days_ago / days_ahead produce the dates the freshness branches key on, in the
# SAME timezone the probe computes ages in (UTC). A fixture written with a
# local-midnight date would flip verdict by timezone, which is a selftest that
# fails for whoever runs it in the wrong hemisphere rather than for a defect.
days_ago()   { python3 -c 'import datetime,sys;print((datetime.datetime.now(datetime.timezone.utc).date()-datetime.timedelta(days=int(sys.argv[1]))).isoformat())' "$1"; }
days_ahead() { python3 -c 'import datetime,sys;print((datetime.datetime.now(datetime.timezone.utc).date()+datetime.timedelta(days=int(sys.argv[1]))).isoformat())' "$1"; }

# fixture makes a fresh empty scratch repo AND enters it. It does not print the
# path for the caller to `cd "$(fixture)"`: command substitution runs in a
# subshell, so the FIXTURE assignment would be lost and every case would run in
# the selftest's own working directory instead. That is not hypothetical -- it
# was the first form of this helper, and it turned the advisory-promise loop
# below into six runs against production-skills' own root, all NA, all
# "passing" over nothing measured. A helper that silently tests the wrong
# directory is the vacuous shape this whole file exists to refuse, so the
# assignment stays in the caller's shell.
fixture() { # fixture -> a fresh empty scratch repo, entered
  FIXTURE="$(mktemp -d "$_tmproot/fix.XXXXXX")"
  cd "$FIXTURE" || { echo "load-rows selftest: cannot enter scratch fixture" >&2; exit 2; }
}

verdict() { # verdict <row-fn> -> "<row-name>|<VERDICT>|<evidence>"
  ROWS=(); fails=0; passes=0; nas=0
  "$1"
  if (( ${#ROWS[@]} != 1 )); then
    # SILENCE IS NOT A VERDICT, and neither is a double emission. A row
    # function that emits nothing would make every substring check compare ""
    # against "" if this printed an empty line, so it prints a diagnosis.
    printf 'NO-ROW|EMITTED-%d|the row function emitted %d rows, not 1' "${#ROWS[@]}" "${#ROWS[@]}"
    return
  fi
  printf '%s' "${ROWS[0]}"
}

expect() { # expect <case-name> <row-fn> <want-verdict> <want-evidence-substring>
  local name="$1" fn="$2" want="$3" sub="$4" got n v e
  cases=$((cases+1))
  cd "$FIXTURE" || { printf '  FAIL %-58s could not enter fixture\n' "$name"; bad=$((bad+1)); return; }
  got="$(verdict "$fn")"
  cd "$BASE" || true
  n="${got%%|*}"; got="${got#*|}"; v="${got%%|*}"; e="${got#*|}"
  if [[ "$n" != "$ROW_NAME" ]]; then
    printf '  FAIL %-58s row name %s, wanted %s\n' "$name" "$n" "$ROW_NAME" >&2
    bad=$((bad+1)); return
  fi
  if [[ "$v" != "$want" ]]; then
    printf '  FAIL %-58s want=%s got=%s :: %s\n' "$name" "$want" "$v" "$e" >&2
    bad=$((bad+1)); return
  fi
  if [[ -n "$sub" && "$e" != *"$sub"* ]]; then
    printf '  FAIL %-58s %s but evidence lacks %q :: %s\n' "$name" "$v" "$sub" "$e" >&2
    bad=$((bad+1)); return
  fi
  # AN EVIDENCE-FREE ROW IS A FINDING IN ITS OWN RIGHT, in EVERY verdict and
  # not only in PASS, which is the one `row` guards. A FAIL that names no
  # defect leaves softening the probe as the only available fix, and an NA with
  # no reason is indistinguishable from a dimension nobody thought about.
  if [[ -z "${e// /}" ]]; then
    printf '  FAIL %-58s %s with EMPTY evidence\n' "$name" "$v" >&2
    bad=$((bad+1)); return
  fi
  printf '  ok   %-58s %s\n' "$name" "$v"
}

echo "load-rows selftest: start (probe: $PROBE, window: ${LOAD_MAX_AGE_DAYS}d)"

# --- load-baseline (dimension 25) -------------------------------------------
ROW_NAME="load-baseline"
echo "load-baseline:"

# A spec block plus a good document, reused by the cases that vary one thing.
spec_with_target() { printf 'load_baseline:\n  margin_target: %s\n' "$1" > production.yaml; }
good_doc() { # good_doc <measured-date> <saturation> <margin>
  mkdir -p benchmarks/load
  { printf '# Load baseline\n\n'
    printf 'measured: %s\n' "$1"
    printf 'saturation point: %s\n' "$2"
    printf 'margin: %s\n' "$3"
  } > benchmarks/load/baseline.md
}

# --- the two NA paths. Both mean UNASKED, and they are distinguished because
# --- "we decided not to" and "nobody has ever been asked" are different facts.
fixture
printf 'out_of_scope:\n  - load_baseline: >\n      no capacity question: this is a one-shot migration tool.\n' > production.yaml
mkdir -p benchmarks/load; : > benchmarks/load/baseline.md   # present, and irrelevant: a decline wins
cd "$BASE"
expect "ratified decline wins over everything else" load_baseline_row NA "ratified decline"

fixture
printf 'service:\n  name: legacy\n  tier: 2\n' > production.yaml
cd "$BASE"
expect "spec predates dimension 25 (no block, no dir)" load_baseline_row NA "predates dimension 25"

# --- engagement: either the spec block OR the benchmarks/load/ directory
fixture
spec_with_target 3x
cd "$BASE"
expect "spec declares the block, artifact missing" load_baseline_row FAIL "does not exist"

fixture
printf 'service:\n  name: svc\n' > production.yaml
mkdir -p benchmarks/load          # the directory alone is an obligation
cd "$BASE"
expect "benchmarks/load/ alone engages the row" load_baseline_row FAIL "benchmarks/load/ exists"

# --- the TARGET is scored before the document, so the finding names the file
# --- that is actually wrong.
fixture
printf 'load_baseline:\n  notes: ran a load test once\n' > production.yaml
good_doc "$(days_ago 1)" "12000 rps" "3.4x"
cd "$BASE"
expect "block declared but no margin_target" load_baseline_row FAIL "declares no load_baseline.margin_target"

fixture
spec_with_target TBD
good_doc "$(days_ago 1)" "12000 rps" "3.4x"
cd "$BASE"
expect "margin_target is a placeholder (TBD)" load_baseline_row FAIL "declares no load_baseline.margin_target"

fixture
spec_with_target "plenty of headroom"
good_doc "$(days_ago 1)" "12000 rps" "3.4x"
cd "$BASE"
expect "margin_target is prose, not a quantity" load_baseline_row FAIL "must START with the number"

# --- freshness, read from INSIDE the document
fixture
spec_with_target 3x
mkdir -p benchmarks/load
printf '# Load baseline\n\nsaturation point: 12000 rps\nmargin: 3.4x\n' > benchmarks/load/baseline.md
cd "$BASE"
expect "no measurement date at all" load_baseline_row FAIL "no parseable measurement date"

fixture
spec_with_target 3x
good_doc "2026-02-31" "12000 rps" "3.4x"   # well-formed, and not a real day
cd "$BASE"
expect "a date that looks real and is not" load_baseline_row FAIL "could not compute the age"

fixture
spec_with_target 3x
good_doc "$(days_ahead 3)" "12000 rps" "3.4x"
cd "$BASE"
expect "a measurement stamped in the future" load_baseline_row FAIL "in the FUTURE"

fixture
spec_with_target 3x
good_doc "$(days_ago $((LOAD_MAX_AGE_DAYS + 1)))" "12000 rps" "3.4x"
cd "$BASE"
expect "one day past the window is stale" load_baseline_row FAIL "day(s) ago (limit ${LOAD_MAX_AGE_DAYS})"

fixture
spec_with_target 3x
good_doc "$(days_ago "$LOAD_MAX_AGE_DAYS")" "12000 rps" "3.4x"
cd "$BASE"
expect "exactly at the window is still fresh" load_baseline_row PASS "day(s) old, limit ${LOAD_MAX_AGE_DAYS}"

# --- the saturation point must be a NUMBER where the number belongs. These two
# --- are the keyword-grep forms: both documents contain the phrase, neither
# --- contains the measurement.
fixture
spec_with_target 3x
mkdir -p benchmarks/load
{ printf 'measured: %s\n' "$(days_ago 1)"
  printf 'saturation point: not measured yet -- see the ticket\n'
  printf 'margin: 3.4x\n'; } > benchmarks/load/baseline.md
cd "$BASE"
expect "'saturation point: not measured yet' is not a number" load_baseline_row FAIL "declares no saturation point"

fixture
spec_with_target 3x
mkdir -p benchmarks/load
{ printf 'measured: %s\n' "$(days_ago 1)"
  printf 'We have never found the saturation point of this service under load.\n'
  printf 'margin: 3.4x\n'; } > benchmarks/load/baseline.md
cd "$BASE"
expect "a PARAGRAPH about the saturation point is not a field" load_baseline_row FAIL "declares no saturation point"

# --- the margin must be a comparable quantity, and comparable to THIS target
fixture
spec_with_target 3x
good_doc "$(days_ago 1)" "12000 rps" "comfortable"
cd "$BASE"
expect "'margin: comfortable' does not normalise" load_baseline_row FAIL "declares no parseable margin"

fixture
spec_with_target 3x
good_doc "$(days_ago 1)" "12000 rps" "150%"
cd "$BASE"
expect "percent margin against a factor target is refused" load_baseline_row FAIL "different quantities"

fixture
spec_with_target 3x
good_doc "$(days_ago 1)" "12000 rps" "2x"
cd "$BASE"
expect "a margin BELOW the declared target is a finding" load_baseline_row FAIL "does not meet what"

# --- and the passes
fixture
spec_with_target 3x
good_doc "$(days_ago 2)" "12000 rps sustained, p99 under 250ms" "3.4x expected peak"
cd "$BASE"
expect "factor margin meets a factor target" load_baseline_row PASS "meets the declared target"

fixture
spec_with_target 250%
good_doc "$(days_ago 2)" "900 msg/s" "300% of expected peak"
cd "$BASE"
expect "percent margin meets a percent target" load_baseline_row PASS "meets the declared target"

fixture
spec_with_target 3x
mkdir -p benchmarks/load
{ printf '# Load baseline\n\n'
  printf -- '- **Measured on**: %s\n' "$(days_ago 5)"
  printf -- '- **Saturation point**: 12000 rps\n'
  printf -- '- **Headroom**: 3.1x expected peak\n'; } > benchmarks/load/baseline.md
cd "$BASE"
expect "real markdown decoration parses (bullets, bold)" load_baseline_row PASS "meets the declared target"

# --- a markdown TABLE is documented as NOT a field. Pinned so the limit is a
# --- decision on record rather than a surprise: a two-cell row has no colon,
# --- and accepting it would mean accepting "the key appears on a line".
fixture
spec_with_target 3x
mkdir -p benchmarks/load
{ printf 'measured: %s\n' "$(days_ago 1)"
  printf '| saturation point | 12000 rps |\n'
  printf '| margin | 3.4x |\n'; } > benchmarks/load/baseline.md
cd "$BASE"
expect "a markdown table cell is not a field (stated limit)" load_baseline_row FAIL "declares no saturation point"

# --- error-handling-fitness (Yuan et al., OSDI 2014) -------------------------
ROW_NAME="error-handling-fitness"
echo "error-handling-fitness:"

fixture
cd "$BASE"
expect "absent script is UNASKED, not clean" error_handling_fitness_row NA "prod-bootstrap"

fixture
mkdir -p scripts
printf '#!/usr/bin/env bash\nexit 0\n' > scripts/error-handling-fitness.sh
chmod 644 scripts/error-handling-fitness.sh
cd "$BASE"
expect "present but not executable is a FAIL, not a PASS" error_handling_fitness_row FAIL "not executable"

fixture
mkdir -p scripts
printf '#!/usr/bin/env bash\necho "3 empty error handlers in internal/app"\nexit 1\n' > scripts/error-handling-fitness.sh
chmod +x scripts/error-handling-fitness.sh
cd "$BASE"
expect "a red fitness script reds the row, with its message" error_handling_fitness_row FAIL "3 empty error handlers"

# A script that reds SILENTLY still has to produce a finding. An evidence-free
# FAIL is the worst output this probe can produce.
fixture
mkdir -p scripts
printf '#!/usr/bin/env bash\nexit 7\n' > scripts/error-handling-fitness.sh
chmod +x scripts/error-handling-fitness.sh
cd "$BASE"
expect "a SILENT red still names its exit status" error_handling_fitness_row FAIL "exit 7"

fixture
mkdir -p scripts
printf '#!/usr/bin/env bash\necho "scanned 214 handlers, 0 violations"\nexit 0\n' > scripts/error-handling-fitness.sh
chmod +x scripts/error-handling-fitness.sh
cd "$BASE"
expect "green fitness script passes, quoting what it measured" error_handling_fitness_row PASS "scanned 214 handlers"

# A green script that prints NOTHING must not produce a PASS with empty
# evidence -- `row` would convert that into a FAIL, which is the right guard
# and the wrong verdict here, so the row supplies its own text.
fixture
mkdir -p scripts
printf '#!/usr/bin/env bash\nexit 0\n' > scripts/error-handling-fitness.sh
chmod +x scripts/error-handling-fitness.sh
cd "$BASE"
expect "green and silent still yields non-empty evidence" error_handling_fitness_row PASS "EXECUTED clean"

# --- simulation-advisory (dimension 27) -------------------------------------
ROW_NAME="simulation-advisory"
echo "simulation-advisory:"

fixture
printf 'sim:\n\t@echo simulating\n' > Makefile
mkdir -p verification/simulation
printf 'package simulation\n' > verification/simulation/sim_test.go
cd "$BASE"
expect "target + lane directory is the advisory PASS" simulation_advisory_row PASS "sim lane present (advisory)"

fixture
printf 'sim:\n\t@echo simulating\n' > Makefile
mkdir -p verification/simulation      # deliberately EMPTY
cd "$BASE"
expect "an empty lane passes, and the count says so" simulation_advisory_row PASS "(0 file(s))"

fixture
printf 'sim:\n\t@echo simulating\n' > Makefile
cd "$BASE"
expect "a target with no lane directory is NA" simulation_advisory_row NA "no verification/simulation/"

fixture
mkdir -p verification/simulation
cd "$BASE"
expect "a lane directory with no target is NA" simulation_advisory_row NA "no 'sim:' target"

fixture
cd "$BASE"
expect "neither half present is NA, naming both" simulation_advisory_row NA "no verification/simulation/"

# `.PHONY: sim` NAMES the target without defining it. The distinction is the
# same one the secret-scan row had to learn between a job DEFINITION and a
# mention of one, and it is the only way this row can be wrong in the
# direction that flatters.
fixture
printf '.PHONY: sim\nverify:\n\t@echo other\n' > Makefile
mkdir -p verification/simulation
cd "$BASE"
expect ".PHONY: sim is a mention, not a target" simulation_advisory_row NA "no 'sim:' target"

# THE TWO CASES THAT ACTUALLY DISCRIMINATE THE ANCHOR, added after mutation
# testing said so. Replacing the row's `^sim:` with an unanchored `sim:` left
# the whole matrix GREEN: `.PHONY: sim` has no colon AFTER the word, so it does
# not contain the substring `sim:` either, and the case above pins a
# distinction the mutation never crossed. A case that cannot fail under the
# weakening it was written for is decoration -- exactly the vacuity this file
# exists to refuse, found in this file.
#
# These two carry `sim:` as a SUBSTRING and must still be NA:
#   - a comment documenting the target, which is the standard way a Makefile
#     mentions a lane it does not have yet;
#   - a DIFFERENT target whose name merely ends in `sim` (`run-sim:`), which is
#     how a rename quietly re-satisfies an unanchored matcher.
fixture
printf '# sim: run the deterministic simulation lane (planned)\nverify:\n\t@echo other\n' > Makefile
mkdir -p verification/simulation
cd "$BASE"
expect "a COMMENT naming sim: is not a target" simulation_advisory_row NA "no 'sim:' target"

fixture
printf 'run-sim:\n\t@echo not the declared target name\n' > Makefile
mkdir -p verification/simulation
cd "$BASE"
expect "run-sim: is a different target, not sim" simulation_advisory_row NA "no 'sim:' target"

# THE PROMISE, EXECUTED. Dimension 27 is advisory: this row must not be able to
# FAIL. Every fixture above is replayed here and the verdict set is asserted to
# contain no FAIL at all -- including the empty-evidence path, since `row`
# itself is in the call chain and would have converted a blank PASS into one.
echo "simulation-advisory (the advisory promise):"
sim_fails=0; sim_seen=0
for _shape in "target+lane" "target-only" "lane-only" "neither" "phony-only" "empty-lane" "comment-only" "renamed-target"; do
  fixture
  case "$_shape" in
    target+lane) printf 'sim:\n\t@echo s\n' > Makefile; mkdir -p verification/simulation; : > verification/simulation/a.go ;;
    target-only) printf 'sim:\n\t@echo s\n' > Makefile ;;
    lane-only)   mkdir -p verification/simulation ;;
    neither)     : ;;
    phony-only)  printf '.PHONY: sim\n' > Makefile; mkdir -p verification/simulation ;;
    empty-lane)  printf 'sim:\n\t@echo s\n' > Makefile; mkdir -p verification/simulation ;;
    comment-only) printf '# sim: planned\nverify:\n\t@echo o\n' > Makefile; mkdir -p verification/simulation ;;
    renamed-target) printf 'run-sim:\n\t@echo o\n' > Makefile; mkdir -p verification/simulation ;;
  esac
  _got="$(verdict simulation_advisory_row)"
  cd "$BASE"
  sim_seen=$((sim_seen+1))
  [[ "${_got#*|}" == FAIL* ]] && { echo "  FAIL advisory row produced a FAIL on shape '$_shape': $_got" >&2; sim_fails=$((sim_fails+1)); }
done
cases=$((cases+1))
if (( sim_seen == 0 )); then
  # A loop that ran zero shapes would print the reassuring line below over
  # nothing measured. Zero inputs is a failure, never a pass.
  echo "  FAIL the advisory-promise loop exercised ZERO shapes" >&2; bad=$((bad+1))
elif (( sim_fails == 0 )); then
  printf '  ok   %-58s %d shapes, no FAIL\n' "the advisory row never produces FAIL" "$sim_seen"
else
  bad=$((bad+1))
fi

echo
if (( cases == 0 )); then
  echo "load-rows selftest: ZERO cases ran -- that is a broken selftest, not a green one" >&2
  exit 1
fi
if (( bad != 0 )); then
  echo "load-rows selftest: ${bad} of ${cases} case(s) FAILED" >&2
  exit 1
fi
echo "load-rows selftest: ok -- ${cases} case(s), every verdict of all three rows demonstrated"
exit 0
