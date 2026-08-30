#!/usr/bin/env bash
# load-rows-selftest.sh -- the verdict matrix for the five rows verify-standard.sh
# gained with dimensions 25 and 27 and with the 2026-08-27 wiring landing:
# `load-baseline`, `error-handling-fitness`, `simulation-advisory`,
# `crash-only-state-identity` and `differential-observability`.
#
# THE WIRING CASES (added 2026-08-27 when the deferred wiring-rows fragment was
# landed) are the ones worth reading first, because each of them pins a verdict
# that a plausible simplification of the probe would silently invert:
#
#   * error-handling-fitness now FAILs when the script exists and check-fast's
#     OWN RECIPE no longer invokes it. The case that discriminates the awk from
#     the obvious whole-Makefile grep is `standalone target still matches a
#     whole-file grep`: it is the fragment's measured miss, reproduced here as
#     a fixture rather than quoted as a claim.
#   * differential-observability FAILs when the alert's client half is replaced
#     by a series this service emits. Two of its cases exist only because the
#     fragment's author measured the row PASSING over exactly that substitution
#     -- once because PromQL builtins counted as external series, once because a
#     COMMENT inside the fence still named the series the expression had
#     stopped using. Both are pinned below and both go RED without their filter.
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
eval "$(grep -m1 -E '^KILL_DURABILITY=' "$PROBE")"
for _v in SPEC LOAD_BASELINE LOAD_MAX_AGE_DAYS EHF KILL_DURABILITY; do
  [[ -n "${!_v:-}" ]] || { echo "load-rows selftest: could not lift $_v from $PROBE" >&2; exit 2; }
done
[[ "$LOAD_MAX_AGE_DAYS" =~ ^[0-9]+$ ]] || { echo "load-rows selftest: LOAD_MAX_AGE_DAYS lifted as '$LOAD_MAX_AGE_DAYS', not a number" >&2; exit 2; }

# `waived` is lifted too, and not restated: the differential-observability row
# reaches its NA through it, and a restated copy would let the real one drift
# (its id matcher has already been fixed once, for a waiver whose `id:` did not
# sit on the dash line).
for _fn in row declined waived placeholder_value spec_field \
           load_field load_margin_norm load_age_days \
           load_baseline_row error_handling_fitness_row simulation_advisory_row \
           crash_only_state_row differential_observability_row; do
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

# to_base -- return to the repo root, and REFUSE to continue if it fails.
#
# 59 bare `cd "$BASE"` calls sat here until 2026-08-30, flagged by
# `shellcheck -S warning` as SC2164 and never reviewed because the gate only
# ran at -S error. The likelihood is low and the consequence is not: every one
# of them is followed by an `expect` that evaluates a ROW against the current
# directory, so a cd that silently failed would leave the assertion measuring
# the fixture it was supposed to have left -- a selftest returning confident
# verdicts about the wrong tree.
#
# One guarded helper rather than 59 hand-edited `|| exit`s: the same fix, and
# the next person adding a case cannot forget it.
to_base() { cd "$BASE" || { echo "load-rows selftest: cannot return to $BASE" >&2; exit 2; }; }
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

# fails/passes/nas are reset here and INCREMENTED by the row's own `row()`.
# The linter sees the assignment and not the indirect use. The directive is at
# FUNCTION level: placed on the assignment line it covers only the first of the
# four commands there, which is why three of them kept being reported.
# shellcheck disable=SC2034
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
to_base
expect "ratified decline wins over everything else" load_baseline_row NA "ratified decline"

fixture
printf 'service:\n  name: legacy\n  tier: 2\n' > production.yaml
to_base
expect "spec predates dimension 25 (no block, no dir)" load_baseline_row NA "predates dimension 25"

# --- engagement: either the spec block OR the benchmarks/load/ directory
fixture
spec_with_target 3x
to_base
expect "spec declares the block, artifact missing" load_baseline_row FAIL "does not exist"

fixture
printf 'service:\n  name: svc\n' > production.yaml
mkdir -p benchmarks/load          # the directory alone is an obligation
to_base
expect "benchmarks/load/ alone engages the row" load_baseline_row FAIL "benchmarks/load/ exists"

# --- the TARGET is scored before the document, so the finding names the file
# --- that is actually wrong.
fixture
printf 'load_baseline:\n  notes: ran a load test once\n' > production.yaml
good_doc "$(days_ago 1)" "12000 rps" "3.4x"
to_base
expect "block declared but no margin_target" load_baseline_row FAIL "declares no load_baseline.margin_target"

fixture
spec_with_target TBD
good_doc "$(days_ago 1)" "12000 rps" "3.4x"
to_base
expect "margin_target is a placeholder (TBD)" load_baseline_row FAIL "declares no load_baseline.margin_target"

fixture
spec_with_target "plenty of headroom"
good_doc "$(days_ago 1)" "12000 rps" "3.4x"
to_base
expect "margin_target is prose, not a quantity" load_baseline_row FAIL "must START with the number"

# --- freshness, read from INSIDE the document
fixture
spec_with_target 3x
mkdir -p benchmarks/load
printf '# Load baseline\n\nsaturation point: 12000 rps\nmargin: 3.4x\n' > benchmarks/load/baseline.md
to_base
expect "no measurement date at all" load_baseline_row FAIL "no parseable measurement date"

fixture
spec_with_target 3x
good_doc "2026-02-31" "12000 rps" "3.4x"   # well-formed, and not a real day
to_base
expect "a date that looks real and is not" load_baseline_row FAIL "could not compute the age"

fixture
spec_with_target 3x
good_doc "$(days_ahead 3)" "12000 rps" "3.4x"
to_base
expect "a measurement stamped in the future" load_baseline_row FAIL "in the FUTURE"

fixture
spec_with_target 3x
good_doc "$(days_ago $((LOAD_MAX_AGE_DAYS + 1)))" "12000 rps" "3.4x"
to_base
expect "one day past the window is stale" load_baseline_row FAIL "day(s) ago (limit ${LOAD_MAX_AGE_DAYS})"

fixture
spec_with_target 3x
good_doc "$(days_ago "$LOAD_MAX_AGE_DAYS")" "12000 rps" "3.4x"
to_base
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
to_base
expect "'saturation point: not measured yet' is not a number" load_baseline_row FAIL "declares no saturation point"

fixture
spec_with_target 3x
mkdir -p benchmarks/load
{ printf 'measured: %s\n' "$(days_ago 1)"
  printf 'We have never found the saturation point of this service under load.\n'
  printf 'margin: 3.4x\n'; } > benchmarks/load/baseline.md
to_base
expect "a PARAGRAPH about the saturation point is not a field" load_baseline_row FAIL "declares no saturation point"

# --- the margin must be a comparable quantity, and comparable to THIS target
fixture
spec_with_target 3x
good_doc "$(days_ago 1)" "12000 rps" "comfortable"
to_base
expect "'margin: comfortable' does not normalise" load_baseline_row FAIL "declares no parseable margin"

fixture
spec_with_target 3x
good_doc "$(days_ago 1)" "12000 rps" "150%"
to_base
expect "percent margin against a factor target is refused" load_baseline_row FAIL "different quantities"

fixture
spec_with_target 3x
good_doc "$(days_ago 1)" "12000 rps" "2x"
to_base
expect "a margin BELOW the declared target is a finding" load_baseline_row FAIL "does not meet what"

# --- and the passes
fixture
spec_with_target 3x
good_doc "$(days_ago 2)" "12000 rps sustained, p99 under 250ms" "3.4x expected peak"
to_base
expect "factor margin meets a factor target" load_baseline_row PASS "meets the declared target"

fixture
spec_with_target 250%
good_doc "$(days_ago 2)" "900 msg/s" "300% of expected peak"
to_base
expect "percent margin meets a percent target" load_baseline_row PASS "meets the declared target"

fixture
spec_with_target 3x
mkdir -p benchmarks/load
{ printf '# Load baseline\n\n'
  printf -- '- **Measured on**: %s\n' "$(days_ago 5)"
  printf -- '- **Saturation point**: 12000 rps\n'
  printf -- '- **Headroom**: 3.1x expected peak\n'; } > benchmarks/load/baseline.md
to_base
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
to_base
expect "a markdown table cell is not a field (stated limit)" load_baseline_row FAIL "declares no saturation point"

# --- error-handling-fitness (Yuan et al., OSDI 2014) -------------------------
ROW_NAME="error-handling-fitness"
echo "error-handling-fitness:"

# ehf_script <exit-code> [message] -- the gate itself, executable by default.
ehf_script() {
  mkdir -p scripts
  { printf '#!/usr/bin/env bash\n'
    [[ -n "${2:-}" ]] && printf 'echo %q\n' "$2"
    printf 'exit %s\n' "$1"; } > scripts/error-handling-fitness.sh
  chmod +x scripts/error-handling-fitness.sh
}
# wired_makefile -- a check-fast whose OWN RECIPE calls the gate. Every case
# below that is about the SCRIPT has to write one, because the row refuses an
# unwired gate before it ever runs it; a fixture without this file would report
# the wiring FAIL and silently stop testing what its name says it tests.
wired_makefile() {
  { printf 'check-fast:\n'
    printf '\t@echo "cheap gate"\n'
    printf '\tgo vet ./...\n'
    printf '\t$(MAKE) error-handling-fitness\n'
    printf '\n'
    printf 'error-handling-fitness:\n'
    printf '\tbash scripts/error-handling-fitness.sh\n'; } > Makefile
}

fixture
to_base
expect "absent script is UNASKED, not clean" error_handling_fitness_row NA "prod-bootstrap"

# The mode bit is scored BEFORE the wiring, and this fixture has no Makefile at
# all -- so it also pins the precedence: the first thing wrong is the thing
# reported, and CI cannot start a non-executable gate however well it is wired.
fixture
mkdir -p scripts
printf '#!/usr/bin/env bash\nexit 0\n' > scripts/error-handling-fitness.sh
chmod 644 scripts/error-handling-fitness.sh
to_base
expect "present but not executable is a FAIL, not a PASS" error_handling_fitness_row FAIL "not executable"

# --- THE WIRING (landed 2026-08-27). A gate the cheap gate no longer calls is
# --- a file, and the row that only EXECUTED the script called it green.
fixture
ehf_script 0 "scanned 214 handlers, 0 violations"
printf 'check-fast:\n\t@echo "cheap gate"\n\tgo vet ./...\n' > Makefile
to_base
expect "check-fast recipe stripped of the invocation" error_handling_fitness_row FAIL "OWN RECIPE does not invoke it"

# THE MEASURED MISS, reproduced as a fixture. This Makefile still contains the
# text `scripts/error-handling-fitness.sh` -- in the standalone target's recipe
# -- so a whole-file grep PASSES it while check-fast runs neither. The awk is
# the difference, and this case is what would go red if someone replaced it.
fixture
ehf_script 0 "scanned 214 handlers, 0 violations"
{ printf 'check-fast:\n\t@echo "cheap gate"\n\tgo vet ./...\n'
  printf '\n'
  printf 'error-handling-fitness:\n'
  printf '\tbash scripts/error-handling-fitness.sh\n'; } > Makefile
to_base
expect "standalone target still matches a whole-file grep" error_handling_fitness_row FAIL "OWN RECIPE does not invoke it"

# A repo with the gate and NO Makefile has no cheap gate to be wired into. It
# fails closed, which is the same answer `cheap-gate` gives it.
fixture
ehf_script 0 "scanned 214 handlers, 0 violations"
to_base
expect "no Makefile at all is not 'wired'" error_handling_fitness_row FAIL "OWN RECIPE does not invoke it"

# THE THIRD REPAIR, found while landing rather than in the fragment: a recipe
# line that is COMMENTED OUT is a line make does not run. It is the likeliest
# way a gate is actually disabled, and it is the alert fence's "a mention is not
# a citation" one file over.
#
# THE TAB-THEN-HASH FORM IS THE ONE THAT DISCRIMINATES, and getting this wrong
# is recorded here because it happened while writing the case. The first
# fixture used `#<TAB>$(MAKE) ...` -- a line starting with `#` -- and it went
# FAIL with and without the repair, because the awk ends the recipe at the
# first line that is not tab-indented, so that text was never in `_cf` at all.
# A case that cannot fail under the weakening it was written for is decoration.
# `<TAB>#$(MAKE) ...` IS still inside the recipe (make hands it to the shell,
# which ignores it), so only the sed removes it: drop the sed and this case
# goes PASS.
fixture
ehf_script 0 "scanned 214 handlers, 0 violations"
{ printf 'check-fast:\n\t@echo "cheap gate"\n'
  printf '\t# $(MAKE) error-handling-fitness   # disabled while the lint lands\n'; } > Makefile
to_base
expect "a COMMENTED-OUT invocation is not wiring" error_handling_fitness_row FAIL "OWN RECIPE does not invoke it"

# The OTHER comment shape, kept as its own case because it is caught by a
# DIFFERENT mechanism: a line starting with `#` is not tab-indented, so the awk
# has already ended the recipe there. Pinned so the two are not confused again.
fixture
ehf_script 0 "scanned 214 handlers, 0 violations"
{ printf 'check-fast:\n\t@echo "cheap gate"\n'
  printf '#\t$(MAKE) error-handling-fitness\n'; } > Makefile
to_base
expect "a hash-first line has already ended the recipe" error_handling_fitness_row FAIL "OWN RECIPE does not invoke it"

# ...and the converse, so the strip cannot be widened into refusing real lines:
# a live invocation with a trailing comment is still an invocation.
fixture
ehf_script 0 "scanned 214 handlers, 0 violations"
{ printf 'check-fast:\n\t@echo "cheap gate"\n'
  printf '\t$(MAKE) error-handling-fitness   # the OSDI-2014 handler shapes\n'; } > Makefile
to_base
expect "a trailing comment does not un-wire a real call" error_handling_fitness_row PASS "scanned 214 handlers"

# The recipe may call the script DIRECTLY rather than through $(MAKE); both are
# the cheap gate running it, and only the wiring is being asserted.
fixture
ehf_script 0 "scanned 214 handlers, 0 violations"
printf 'check-fast:\n\t@echo "cheap gate"\n\tbash scripts/error-handling-fitness.sh\n' > Makefile
to_base
expect "a direct script call in the recipe is wiring too" error_handling_fitness_row PASS "scanned 214 handlers"

# The recipe ends where the tab-indentation does. A later target that DOES call
# the gate is not check-fast calling it.
fixture
ehf_script 0 "scanned 214 handlers, 0 violations"
{ printf 'check-fast:\n\t@echo "cheap gate"\n'
  printf 'verify:\n\t$(MAKE) error-handling-fitness\n'; } > Makefile
to_base
expect "a LATER target's recipe is not check-fast's" error_handling_fitness_row FAIL "OWN RECIPE does not invoke it"

# --- and, wired, the landed execute-and-report behaviour is unchanged.
fixture
ehf_script 1 "3 empty error handlers in internal/app"
wired_makefile
to_base
expect "a red fitness script reds the row, with its message" error_handling_fitness_row FAIL "3 empty error handlers"

# A script that reds SILENTLY still has to produce a finding. An evidence-free
# FAIL is the worst output this probe can produce.
fixture
ehf_script 7
wired_makefile
to_base
expect "a SILENT red still names its exit status" error_handling_fitness_row FAIL "exit 7"

fixture
ehf_script 0 "scanned 214 handlers, 0 violations"
wired_makefile
to_base
expect "green fitness script passes, quoting what it measured" error_handling_fitness_row PASS "scanned 214 handlers"

# A green script that prints NOTHING must not produce a PASS with empty
# evidence -- `row` would convert that into a FAIL, which is the right guard
# and the wrong verdict here, so the row supplies its own text.
fixture
ehf_script 0
wired_makefile
to_base
expect "green and silent still yields non-empty evidence" error_handling_fitness_row PASS "EXECUTED clean"

# The PASS carries BOTH measurements, so a reader can tell "it ran" from "the
# cheap gate runs it" without going back to the source.
fixture
ehf_script 0 "scanned 214 handlers, 0 violations"
wired_makefile
to_base
expect "the PASS names the wiring as well as the run" error_handling_fitness_row PASS "check-fast's recipe invokes it"

# --- simulation-advisory (dimension 27) -------------------------------------
ROW_NAME="simulation-advisory"
echo "simulation-advisory:"

fixture
printf 'sim:\n\t@echo simulating\n' > Makefile
mkdir -p verification/simulation
printf 'package simulation\n' > verification/simulation/sim_test.go
to_base
expect "target + lane directory is the advisory PASS" simulation_advisory_row PASS "sim lane present (advisory)"

fixture
printf 'sim:\n\t@echo simulating\n' > Makefile
mkdir -p verification/simulation      # deliberately EMPTY
to_base
expect "an empty lane passes, and the count says so" simulation_advisory_row PASS "(0 file(s))"

fixture
printf 'sim:\n\t@echo simulating\n' > Makefile
to_base
expect "a target with no lane directory is NA" simulation_advisory_row NA "no verification/simulation/"

fixture
mkdir -p verification/simulation
to_base
expect "a lane directory with no target is NA" simulation_advisory_row NA "no 'sim:' target"

fixture
to_base
expect "neither half present is NA, naming both" simulation_advisory_row NA "no verification/simulation/"

# `.PHONY: sim` NAMES the target without defining it. The distinction is the
# same one the secret-scan row had to learn between a job DEFINITION and a
# mention of one, and it is the only way this row can be wrong in the
# direction that flatters.
fixture
printf '.PHONY: sim\nverify:\n\t@echo other\n' > Makefile
mkdir -p verification/simulation
to_base
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
to_base
expect "a COMMENT naming sim: is not a target" simulation_advisory_row NA "no 'sim:' target"

fixture
printf 'run-sim:\n\t@echo not the declared target name\n' > Makefile
mkdir -p verification/simulation
to_base
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
  to_base
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

# --- crash-only-state-identity (Candea & Fox, HotOS IX 2003) -----------------
#
# The scenario needs docker, so the row cannot run it and does not pretend to.
# What it asserts is that the crash scenario COMPARES RECONSTRUCTED STATE, and
# the failure mode is the quiet one: a scenario that checks the records came
# back is a scenario a wrong replay passes.
ROW_NAME="crash-only-state-identity"
echo "crash-only-state-identity:"

kill_script() { # kill_script <assertion-name>
  mkdir -p scripts
  { printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf '# start the service, write records, SIGKILL it, boot it again\n'
    printf '%s() { :; }\n' "$1"
    printf '%s\n' "$1"; } > scripts/kill-durability.sh
  chmod +x scripts/kill-durability.sh
}

fixture
to_base
expect "absent kill scenario is UNASKED, not clean" crash_only_state_row NA "UNASKED"

fixture
kill_script assert_state_identical
to_base
expect "the state assertion present is the PASS" crash_only_state_row PASS "compares reconstructed state"

# THE MUTATION THIS ROW EXISTS FOR: the assertion renamed out of the scenario.
# The scenario still exists, still runs, still passes -- and the property it was
# added for is gone. Named `assert_records_survived` on purpose: that is the
# weaker check the row's own evidence string names as insufficient.
fixture
kill_script assert_records_survived
to_base
expect "the state assertion renamed out is a FAIL" crash_only_state_row FAIL "never that replaying them reconstructs"

# A scenario that MENTIONS the assertion in a comment and does not call it is
# still a scenario that does not assert it -- but this row reads text and
# cannot tell the two apart, so the limit is pinned here as a decision on
# record rather than left to be discovered as a surprise. The non-vacuity of
# the assertion itself is the scenario selftest's job, not this row's.
fixture
mkdir -p scripts
{ printf '#!/usr/bin/env bash\n'
  printf '# TODO: call assert_state_identical once the digest endpoint lands\n'
  printf 'echo records survived\n'; } > scripts/kill-durability.sh
chmod +x scripts/kill-durability.sh
to_base
expect "a COMMENT naming the assertion satisfies it (stated limit)" crash_only_state_row PASS "compares reconstructed state"

# --- differential-observability (Huang et al., HotOS 2017) -------------------
#
# The alert is REAL only if its client half is a series this service does not
# emit. Every FAIL case below is an alert that parses, evaluates, and never
# fires in the failure it was written for.
ROW_NAME="differential-observability"
echo "differential-observability:"

emitted() { # emitted <series>...
  mkdir -p observability
  { printf '# manifest\n'
    for _s in "$@"; do printf -- '- name: %s\n  type: gauge\n  labels: []\n' "$_s"; done
  } > observability/emitted-metrics.yaml
}
gray_alert() { # gray_alert <expression-line>...
  mkdir -p observability
  { printf '## `SvcEventLogNotWritable` (page)\n\n```\nsvc_eventlog_writable == 0\n```\n\n'
    printf '## `SvcGrayFailure` (page)\n\n```\n'
    for _l in "$@"; do printf '%s\n' "$_l"; done
    printf '```\n\n**Meaning:** the service is up according to itself.\n'; } > observability/alerts.md
}

fixture
to_base
expect "neither observability file is UNASKED" differential_observability_row NA "no observability/alerts.md"

fixture
gray_alert 'probe_success < 0.99'
to_base
expect "an alert file with no manifest cannot be scored" differential_observability_row NA "no observability/emitted-metrics.yaml"

fixture
emitted svc_eventlog_writable
gray_alert \
  '  min_over_time(svc_eventlog_writable[10m]) == 1' \
  'and on(instance)' \
  '  avg_over_time(probe_success{job="blackbox"}[10m]) < 0.99'
to_base
expect "an alert citing an out-of-process series is the PASS" differential_observability_row PASS "1 series this service does not emit"

# THE MUTATION THIS ROW EXISTS FOR: the client half replaced by a series this
# service emits about itself. It parses, it evaluates, and in the gray failure
# it is measuring the vantage that is wrong.
fixture
emitted svc_eventlog_writable svc_readyz_stale_never_ready_audits_total
gray_alert \
  '  min_over_time(svc_eventlog_writable[10m]) == 1' \
  'and on(instance)' \
  '  avg_over_time(svc_readyz_stale_never_ready_audits_total[10m]) > 0'
to_base
expect "the client half replaced by a self-emitted series" differential_observability_row FAIL "cites ONLY series this service emits"

# FIRST RECORDED FIRST-PASS REPAIR, pinned as its own case. Without the
# trailing-paren filter `min_over_time` and `avg_over_time` counted as "series
# this service does not emit", and the fixture above PASSED -- the exact
# substitution the row exists to catch, certified green by two PromQL builtins.
# The expression here is deliberately ALL builtins over ONE self-emitted series,
# so removing the filter flips this case from FAIL to PASS.
fixture
emitted svc_eventlog_writable
gray_alert \
  '  min_over_time(svc_eventlog_writable[10m]) == 1' \
  'and on(instance)' \
  '  max_over_time(svc_eventlog_writable[10m]) == 1'
to_base
expect "PromQL builtins are calls, not external series" differential_observability_row FAIL "cites ONLY series this service emits"

# SECOND RECORDED FIRST-PASS REPAIR. With `#` lines left inside the fence, the
# substitution above still PASSED because the COMMENT above the line still
# named the external series the expression had stopped using. A mention is not
# a citation, and this case is what goes green again if the sed is dropped.
fixture
emitted svc_eventlog_writable
gray_alert \
  '# was: avg_over_time(probe_success{job="blackbox"}[10m]) < 0.99' \
  '  min_over_time(svc_eventlog_writable[10m]) == 1' \
  'and on(instance)' \
  '  max_over_time(svc_eventlog_writable[10m]) == 1'
to_base
expect "a comment inside the fence is a mention, not a citation" differential_observability_row FAIL "cites ONLY series this service emits"

# PROSE outside the fence names series too. Counting it would let a paragraph
# about the blackbox exporter satisfy the row.
fixture
emitted svc_eventlog_writable
{ printf '## `SvcGrayFailure` (page)\n\n```\n'
  printf 'min_over_time(svc_eventlog_writable[10m]) == 1\n'
  printf '```\n\n'
  printf 'We should compare this against probe_success from the blackbox exporter.\n'
} > observability/alerts.md
to_base
expect "prose outside the fence is not the expression" differential_observability_row FAIL "cites ONLY series this service emits"

# The next `## ` heading ENDS the section. A different alert's external series
# must not be borrowed by this one.
fixture
emitted svc_eventlog_writable
{ printf '## `SvcGrayFailure` (page)\n\n```\n'
  printf 'min_over_time(svc_eventlog_writable[10m]) == 1\n'
  printf '```\n\n'
  printf '## `SvcProbeDown` (page)\n\n```\n'
  printf 'probe_success{job="blackbox"} < 1\n'
  printf '```\n'
} > observability/alerts.md
to_base
expect "a NEIGHBOURING alert's series is not this one's" differential_observability_row FAIL "cites ONLY series this service emits"

fixture
emitted svc_eventlog_writable
mkdir -p observability
printf '## `SvcEventLogNotWritable` (page)\n\n```\nsvc_eventlog_writable == 0\n```\n' > observability/alerts.md
to_base
expect "no gray-failure alert at all, and no waiver" differential_observability_row FAIL "no alert on the DISAGREEMENT"

# THE WAIVER NA. `waived` is the probe's own function, so this case also drives
# its id matcher and its check-registries handoff -- an expired or unregistered
# waiver leaves the row RED, which is what the FAIL case above already shows.
fixture
emitted svc_eventlog_writable
printf '## `SvcEventLogNotWritable` (page)\n\n```\nsvc_eventlog_writable == 0\n```\n' > observability/alerts.md
mkdir -p registries scripts
printf -- '- obligation: gray-failure alert needs an out-of-process vantage\n  id: gray-failure-no-external-vantage\n  owner: platform\n  expires: 2099-01-01\n' > registries/waivers.yaml
printf '#!/usr/bin/env bash\nexit 0\n' > scripts/check-registries.sh
to_base
expect "a live waiver is the NA, and names itself" differential_observability_row NA "live waiver"

# A waiver for a DIFFERENT id does not cover this obligation. Without this the
# NA above would be satisfied by any waivers.yaml that exists at all.
fixture
emitted svc_eventlog_writable
printf '## `SvcEventLogNotWritable` (page)\n\n```\nsvc_eventlog_writable == 0\n```\n' > observability/alerts.md
mkdir -p registries scripts
printf -- '- obligation: something else entirely\n  id: some-other-waiver\n  owner: platform\n  expires: 2099-01-01\n' > registries/waivers.yaml
printf '#!/usr/bin/env bash\nexit 0\n' > scripts/check-registries.sh
to_base
expect "another waiver's id does not cover this row" differential_observability_row FAIL "no alert on the DISAGREEMENT"

echo
if (( cases == 0 )); then
  echo "load-rows selftest: ZERO cases ran -- that is a broken selftest, not a green one" >&2
  exit 1
fi
if (( bad != 0 )); then
  echo "load-rows selftest: ${bad} of ${cases} case(s) FAILED" >&2
  exit 1
fi
echo "load-rows selftest: ok -- ${cases} case(s), every verdict of all five rows demonstrated"
exit 0
