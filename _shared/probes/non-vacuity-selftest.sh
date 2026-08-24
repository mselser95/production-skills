#!/usr/bin/env bash
# non-vacuity-selftest.sh — prove the non-vacuity CHECKER can fail.
#
# scripts/verify-standard.sh's `invariants-non-vacuity` row decides whether this
# repo's ratified invariants have teeth. That row replaced a keyword grep which
# could not fail, so the checker itself is exactly the kind of thing that must
# be shown to fail rather than assumed to work: a verifier nobody verifies is
# the defect it exists to prevent, one level up.
#
# Five cases, all of them the ways this can silently go green:
#   1. mutation applied, test goes red        -> counted as proven
#   2. mutation applied, test stays green     -> STAYED-GREEN (undetected)
#   3. find-string no longer present          -> find-string-gone (decayed)
#   4. mutation breaks the build              -> MUTATION-BREAKS-BUILD
#   5. package carries no executable check    -> no-executable-check
#
# Cases 2-5 all used to be silent passes at one point or another during
# development, which is why each has a case here rather than a comment.
#
# Usage: bash scripts/tests/non-vacuity-selftest.sh
# Exit:  0 all cases behaved; 1 a case did not.

set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" || exit 2

# ---------------------------------------------------------------------------
# SHARED SOURCE. Vendor this into a repo as scripts/tests/non-vacuity-selftest.sh
# and adapt ONLY the two slots named below. Do not re-author it: three repos
# wrote their own copy of this file in one session and all three shipped the
# SAME defect, because each copied the one before it.
#
# THE DEFECT, so it is never re-introduced: the control case must assert that
# the classifier returns NOTHING. That cannot be written as
#   check "<case>" "" "$actual"
# because check() runs `grep -qF "$expected"`, and an EMPTY fixed pattern
# matches every input. Measured 2026-08-23: the control printed "ok" both when
# the classifier returned nothing AND when it returned a reason -- the control
# of the checker that exists to prove tests are not decoration was itself
# decoration, in both directions. Use check_empty(), which is defined below and
# exists for exactly this. Proven by mutating nv_package_reason to always
# return a reason: the control goes RED, exit 1, and the mutation is bash -n
# clean, so it is a detection and not a build break.
#
# THE TWO REPO-SPECIFIC SLOTS (everything else is generic and must not change):
#   1. `file:` in the "find-string-gone" and "control" fixtures must name a
#      non-test source file that EXISTS in this repo.
#   2. `find:` in the "control" fixture must be a string that IS PRESENT in
#      that file. If it is not, the control classifies as find-string-gone and
#      this selftest reports a checker defect that does not exist.
#   The OTHER fixtures keep a synthetic path on purpose -- they exercise the
#   YAML extractor, which never touches the filesystem.
#
# Runtime derivation of those two slots was attempted and abandoned: the nested
# quoting inside the fixture heredocs broke `bash -n`, and a silently broken
# file in the trusted set is worse than two slots a human fills in.
# ---------------------------------------------------------------------------
PROBE=scripts/verify-standard.sh
[[ -r $PROBE ]] || { echo "selftest: no $PROBE" >&2; exit 2; }

fails=0
check() { # check <case> <expected-substring> <actual>
  # REFUSE AN EMPTY EXPECTED, rather than documenting that callers must not
  # pass one. `grep -qF "" ` matches every input, so an empty pattern turns
  # this into a control that cannot fail -- and the note above only closed the
  # LITERAL form. The third site was `check "..." "${sibling_line##*/}"
  # "${glob_line##*/}"`, where the pattern arrives through a variable: if
  # either grep finds nothing the expected is empty and a real divergence
  # between the two denominators goes green. Found by fd1az on
  # kraken-marketdata after two rounds of fixing the literal form, which is the
  # argument for closing the CLASS in the helper instead of the instances:
  # a fourth site cannot be written by accident now.
  #
  # A case whose correct output is genuinely nothing uses check_empty below.
  if [[ -z "${2//[[:space:]]/}" ]]; then
    echo "  FAIL $1 — check() was given an EMPTY expected pattern, which matches" >&2
    echo "       anything. Use check_empty for a case whose correct output is nothing," >&2
    echo "       or fix the producer that returned nothing here. Actual was: $3" >&2
    fails=$((fails+1))
    return
  fi
  if grep -qF "$2" <<<"$3"; then
    echo "  ok   $1"
  else
    echo "  FAIL $1 — expected to see '$2', got: $3" >&2
    fails=$((fails+1))
  fi
}

# A case whose CORRECT output is NOTHING cannot be expressed with check().
# `check "$case" "" "$actual"` runs `grep -qF "" <<<"$actual"`, and an empty
# fixed pattern matches EVERY line -- including a non-empty one. Measured
# 2026-08-23: the control below printed "ok" both when the classifier returned
# nothing AND when it returned a reason string. So the control of the checker
# that exists to prove tests are not decoration was itself decoration, in both
# directions. It needs its own assertion.
check_empty() { # check_empty <case> <actual>
  if [[ -z "${2//[[:space:]]/}" ]]; then
    echo "  ok   $1"
  else
    echo "  FAIL $1 — expected NO reason at all, got: $2" >&2
    fails=$((fails+1))
  fi
}

# The classifier is the part under test, so SOURCE it out of the probe rather
# than restating it here. An earlier version of this file kept its own copy and
# the copy immediately drifted: the probe was fixed, the copy was not, and the
# selftest went red for the right reason by accident. A selftest that
# reimplements the logic tests the reimplementation.
eval "$(sed -n '/^classify_mutation_result() {/,/^}/p' "$PROBE")"
declare -F classify_mutation_result >/dev/null || {
  echo "selftest: could not source classify_mutation_result from $PROBE" >&2; exit 2; }
classify() { classify_mutation_result "$1"; }

echo "non-vacuity selftest: start"

check "a red test counts as detected" "DETECTED" \
  "$(classify '--- FAIL: TestInvariant_Foo (0.01s)
FAIL')"

check "a green test is NOT detected" "STAYED-GREEN" \
  "$(classify 'ok  	example.com/x/verification/ratified	0.10s')"

check "a build break is not a detection" "MUTATION-BREAKS-BUILD" \
  "$(classify '# example.com/x [build failed]
./health.go:12:3: declared and not used: symbol')"

check "an empty/odd result is not a pass" "NO-VERDICT" \
  "$(classify 'signal: killed')"

# The regression this case exists for: `go test ./verification/...` spans more
# than one package, so the moment a SIBLING package gained tests, its own "ok"
# line was matched before the failing package's FAIL and every mutation was
# classified STAYED-GREEN -- the probe declaring all four ratified invariants
# vacuous when they were not. Order matters, and a neighbour's verdict is not
# this test's verdict.
check "a sibling package's ok never masks a FAIL" "DETECTED" \
  "$(classify 'ok  	example.com/x/verification/conformance	4.80s
--- FAIL: TestInvariant_Foo (0.01s)
FAIL	example.com/x/verification/ratified	0.30s
FAIL')"

# The four unverifiable-package reasons, DRIVEN through the probe's own
# classifier rather than grepped.
#
# These cases used to `grep -F` the probe's source for "find-string-gone" and
# "no-executable-check". A grep cannot tell a branch that works from a branch
# that is dead -- measured: replacing the missing-check guard with
# `if false; then`, leaving the string in the now-unreachable branch, still
# printed ok.
#
# The first fix drove the WHOLE probe per case, which was honest and unusable:
# one full run measures 115s here and this file needs eight of them, and a
# selftest too slow for the cheap gate is a selftest that gets moved out of it.
# So the classifier is sourced, exactly like classify_mutation_result.
eval "$(sed -n '/^extract_pkg_fields() {/,/^}/p' "$PROBE")"
eval "$(sed -n '/^nv_package_reason() {/,/^}/p' "$PROBE")"
declare -F nv_package_reason >/dev/null || {
  echo "selftest: could not source nv_package_reason from $PROBE" >&2; exit 2; }

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# SOURCE FILES THE SELFTEST OWNS, not paths borrowed from the host repo.
#
# Two cases below used to name `internal/app/hub.go`, which exists in
# binance-marketdata and does not exist in bitgo-marketdata -- so the SHARED
# selftest passed in one repo and failed in the other for a reason that had
# nothing to do with the classifier. Measured: bitgo went 0 FAIL -> 2 FAIL on
# the selftest alone, with the probe held constant. A shared gate whose verdict
# depends on which tree it landed in is worse than no gate: it teaches whoever
# meets the red first that the gate is noise.
#
# nv_package_reason tests `[[ -f "$file" ]]`, so an absolute path under the
# scratch works and depends on nothing outside this file.
present_src="${scratch}/present.go"
cat >"$present_src" <<'SRC'
package app

func admit(t item) bool {
	if t.Venue == "" {
		return false
	}
	return true
}
SRC

reason_for() { # reason_for <yaml-body> -> the classifier's verdict
  local f="${scratch}/pkg.yaml"
  printf '%s' "$1" >"$f"
  nv_package_reason "$f" "$(extract_pkg_fields "$f")"
}

check "a package with no check is no-executable-check" "no-executable-check" \
  "$(reason_for 'id: 900
status: RATIFIED
statement: a package with no non_vacuity_check block at all
')"

check "a decayed find-string is find-string-gone" "find-string-gone" \
  "$(reason_for 'id: 901
non_vacuity_check:
  file: '"$present_src"'
  expect_red: TestInvariant_UnvenuedItemsNeverAdmitted
  find: '"'"'this exact string is not in that file and never was'"'"'
  replace: '"'"'nor is this'"'"'
  requires_tags: '"''"'
')"

check "a package naming a missing file is no-such-file" "no-such-file" \
  "$(reason_for 'id: 902
non_vacuity_check:
  file: '"${scratch}"'/this_file_does_not_exist.go
  expect_red: TestInvariant_UnvenuedItemsNeverAdmitted
  find: '"'"'anything'"'"'
  replace: '"'"'anything else'"'"'
  requires_tags: '"''"'
')"

# A mutable, complete package must classify as EMPTY -- the control. Without
# it, a classifier that returned a reason for everything would satisfy the
# three cases above and still break the row.
check_empty "a complete, applicable package has NO reason (control)" \
  "$(reason_for 'id: 904
non_vacuity_check:
  file: '"$present_src"'
  expect_red: TestInvariant_UnvenuedItemsNeverAdmitted
  find: '"'"'if t.Venue == ""'"'"'
  replace: '"'"'if false'"'"'
  requires_tags: '"''"'
')"

# An UNPARSEABLE package is its own reason, not "no check": one is an authoring
# mistake, the other an environment failure, and reporting them identically
# sent a reader to inspect four correct YAML files instead of the interpreter
# error in the same log.
unreadable="${scratch}/903-unreadable.yaml"
printf 'id: 903\n' >"$unreadable"
chmod 000 "$unreadable"
check "an unreadable package is unparseable, NOT no-executable-check" "unparseable" \
  "$(nv_package_reason "$unreadable" "$(extract_pkg_fields "$unreadable" || printf 'PARSE-ERROR')")"
chmod 644 "$unreadable"

# --- WHICH FILES ENTER THE LOOP -------------------------------------------
#
# Every case above tests what the probe does with a package it read. None
# tested which packages it reads at all, and that is where the fail-open was:
# the non-vacuity loop globbed *.yaml while its two siblings glob *.y*ml, so a
# .yml package was COUNTED by ratification-packages and never entered nv_total.
# The row then printed `PASS n/n mutations RE-VERIFIED red` over a set that
# silently excluded one -- the exact shape the row exists to prevent.
#
# Asserted against the probe's own glob line rather than by running it: the two
# denominators must agree on the same file set.
glob_line=$(grep -m1 -oE 'for pkg in "\$RATIFY_QUEUE_DIR"/\*\.[a-z*]+' "$PROBE")
sibling_line=$(grep -m1 -oE 'ls "\$RATIFY_QUEUE_DIR"/\*\.[a-z*]+' "$PROBE")
check "the non-vacuity loop and the package COUNT glob the same files" \
  "${sibling_line##*/}" "${glob_line##*/}"

# And end to end on a scratch queue, because a matching string is not a matching
# file set: a real .yml package must reach the loop.
ymlq="$(mktemp -d)"
cat >"${ymlq}/005-probe.yml" <<'FIX'
id: 005-probe
status: RATIFIED
non_vacuity_check:
  file: internal/app/hub.go
  expect_red: TestInvariant_UnvenuedItemsNeverAdmitted
  find: 'if t.Venue == ""'
  replace: 'if false'
  requires_tags: ''
test:
  function: TestInvariant_UnvenuedItemsNeverAdmitted
FIX
seen=$(eval "ls \"${ymlq}\"/*.y*ml" 2>/dev/null | wc -l | tr -d ' ')
loop=$(eval "ls \"${ymlq}\"$(sed -E 's/.*RATIFY_QUEUE_DIR\"//' <<<"$glob_line")" 2>/dev/null | wc -l | tr -d ' ')
rm -rf "$ymlq"
check "a .yml package reaches the non-vacuity loop, not just the count" "$seen" "$loop"

# --- the CITATION drift branch --------------------------------------------
#
# `ratification-citations` compares each package's cited `test.function`
# against the `expect_red` the non-vacuity check actually executes. It arrived
# as a new parser, a new comparison and a new FAIL row with no selftest -- in a
# file whose whole premise is that a verifier nobody verifies is the defect it
# exists to prevent.
#
# Driven through the probe's OWN functions, sourced the way
# classify_mutation_result is. Running the whole probe per case would be
# honest but unusable: one full run measures 115s here, and these cases need
# four of them -- a selftest too slow for the cheap gate is a selftest that
# gets moved out of it.
eval "$(sed -n '/^extract_pkg_fields() {/,/^}/p' "$PROBE")"
eval "$(sed -n '/^cited_function()/,$p' "$PROBE" | sed -n '1,2p')"
eval "$(sed -n '/^citation_drift() {/,/^}/p' "$PROBE")"
for fn in extract_pkg_fields cited_function executed_function citation_drift; do
  declare -F "$fn" >/dev/null || {
    echo "selftest: could not source $fn from $PROBE" >&2; exit 2; }
done

cite_fixture() { # cite_fixture <expect_red-value> <cited function> -> path
  local f="${scratch}/910-citation.yaml"
  cat >"$f" <<FIX
id: 910-citation
status: RATIFIED
non_vacuity_check:
  file: internal/app/hub.go
  expect_red: $1
  find: 'if t.Venue == ""'
  replace: 'if false'
  requires_tags: ''
test:
  function: $2
FIX
  printf '%s' "$f"
}

check_empty "citation matching the executed test reports NO drift" \
  "$(citation_drift "$(cite_fixture TestInvariant_UnvenuedItemsNeverAdmitted TestInvariant_UnvenuedItemsNeverAdmitted)")"

check "citation drifting from the executed test IS reported" "cites=TestInvariant_UnvenuedItemsNeverAdmitted,executes=TestInvariant_StaleNeverReportsReady" \
  "$(citation_drift "$(cite_fixture TestInvariant_StaleNeverReportsReady TestInvariant_UnvenuedItemsNeverAdmitted)")"

# `expect_red:Foo` -- no space after the colon. Legal YAML, read fine by the
# real parser, and INVISIBLE to the awk this row used to use: the drift check
# skipped silently while the row printed PASS claiming it had compared them.
# Fail-open in the one row whose job is to catch a mismatch.
nospace="$(cite_fixture TestInvariant_StaleNeverReportsReady TestInvariant_UnvenuedItemsNeverAdmitted)"
sed -i.bak 's/expect_red: /expect_red:/' "$nospace" && rm -f "${nospace}.bak"
check "a no-space expect_red still reports drift (was a silent pass)" \
  "executes=TestInvariant_StaleNeverReportsReady" "$(citation_drift "$nospace")"

# A legally single-quoted expect_red must NOT be reported as drift: the awk did
# not strip quoting and reported a mismatch against an identical name.
check_empty "a quoted expect_red is NOT a false drift" \
  "$(citation_drift "$(cite_fixture "'TestInvariant_UnvenuedItemsNeverAdmitted'" TestInvariant_UnvenuedItemsNeverAdmitted)")"

rm -f "${scratch}/910-citation.yaml"

# The trap itself stays a source assertion, and that is a deliberate exception:
# driving it means killing the probe mid-mutation, which would leave a
# production file mutated if the assertion is the thing that is broken. The
# restore-at-startup path is what actually covers that case now.
check "the working tree is restored on INT/TERM too" "EXIT INT TERM" "$(cat "$PROBE")"

# --- the EXTRACTION step, run for real against a fixture ---------------------
#
# Everything above tests classify_mutation_result or greps the probe's source.
# Nothing invoked the parser that reads `non_vacuity_check:` out of a
# ratify-queue package -- and that is the half this change set rewrote.
#
# Executed, before this case existed: sabotaging the parser to print four empty
# lines instead of `found.get(k, "")` left this selftest 8/8 GREEN, while the
# probe row correctly went FAIL with all four packages `no-executable-check`.
# The old `import yaml` version under a python3 without PyYAML did the same.
# So a parser regression was caught only by `make verify-standard`, whose job is
# not a required context, and never by check-fast -- the job that runs THIS file.
#
# The fixture is deliberately hostile in the ways real Go source is: the find
# string carries a colon (which a naive `key: value` split would truncate), an
# apostrophe doubled per YAML's single-quote escape, and a tab.
extract() { # extract <package-yaml> -> five lines: file, expect_red, find, replace, requires_tags
  # Matched on the heredoc MARKER, not the whole first line. Anchoring to the
  # exact line meant that adding a `2>/dev/null` to it silently produced an
  # EMPTY program here, and six cases failed for a reason that had nothing to
  # do with the parser they were testing.
  sed -n "/<<'PYNV'/,/^PYNV$/p" "$PROBE" \
    | sed '1d;$d' | PKG="$1" python3 -
}

nv_fix="$(mktemp -d)"
cat > "${nv_fix}/pkg.yaml" <<'FIXTURE'
id: 999-fixture
status: RATIFIED
non_vacuity_check:
  file: internal/app/hub.go
  expect_red: TestInvariant_Fixture
  find: '	if seq <= last { // guard: don''t regress'
  replace: '	if false {'
  requires_tags: ratified
other_top_level_key: ends the block
  file: NOT-THIS-ONE
FIXTURE

nv_out="$(extract "${nv_fix}/pkg.yaml")"
rm -rf "$nv_fix"

check "extraction reads file" "internal/app/hub.go"      "$(sed -n 1p <<<"$nv_out")"
check "extraction reads expect_red" "TestInvariant_Fixture" "$(sed -n 2p <<<"$nv_out")"
# The whole point: a colon inside the value survives, the doubled quote is
# unescaped back to one, and the leading tab is preserved.
check "extraction keeps a colon in find" "guard: don't regress" "$(sed -n 3p <<<"$nv_out")"
check "extraction keeps the leading tab" "$(printf '\tif seq')"  "$(sed -n 3p <<<"$nv_out")"
check "extraction reads replace" "if false {"             "$(sed -n 4p <<<"$nv_out")"
check "extraction reads requires_tags" "ratified"         "$(sed -n 5p <<<"$nv_out")"
# A new top-level key ends the block: the `file:` nested under it must NOT win.
if [[ "$(sed -n 1p <<<"$nv_out")" == "NOT-THIS-ONE" ]]; then
  echo "  FAIL extraction stops at the next top-level key — it read past the block" >&2
  fails=$((fails+1))
else
  echo "  ok   extraction stops at the next top-level key"
fi

if (( fails > 0 )); then
  echo "non-vacuity selftest: ${fails} case(s) failed" >&2
  exit 1
fi
echo "non-vacuity selftest: all cases behaved"
