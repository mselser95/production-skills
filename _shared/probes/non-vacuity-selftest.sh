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
# --- the five lifted helpers, which nothing asserted ---------------------------
#
# extract_real_tag, count_secret_scan_workflows, grep_x, toolchain_note and
# fold_makefile were all lifted OUT of inline code so this file could source and
# assert them. Two of them carry a comment in the probe saying exactly that.
# None of the five had a single mention here: measured with
# `grep -c '\bextract_real_tag\b' non-vacuity-selftest.sh` -> 0, and the same for
# the other four.
#
# So the probe cited a selftest that did not exist, in the file whose whole
# subject is that a checker cannot tell a citation from a tombstone. fd1az and
# agatticelli both flagged it, on two repositories, and they were right on both.
# A ONE-LINE function needs a different extraction, and getting it wrong is not
# cosmetic: `sed -n "/^fold_makefile() {/,/^}/p"` runs to the NEXT line starting
# with `}`, which is far below, so it slurped the surrounding code and this file
# died on an unbound variable from it. Take the single line when the opening
# line already closes the brace.
# THE SHARED awk LIBRARY COMES FIRST. The four spec walkers interpolate
# `$SPEC_AWK_LIB` into their awk programs, so sourcing a function without it
# yields a program that silently produces NOTHING -- every `check` then compares
# "" against an expectation and reds, which is at least loud. Refuse instead of
# guessing: if the assignment cannot be lifted, the functions below are not the
# ones that run in the probe, and nothing this file reports would be about them.
_libsrc="$(sed -n "/^SPEC_AWK_LIB='/,/^'$/p" "$PROBE")"
if [[ "$(wc -l <<<"$_libsrc")" -lt 5 ]]; then
  echo "selftest: could not lift SPEC_AWK_LIB from $PROBE -- it was renamed or reshaped" >&2
  exit 1
fi
eval "$_libsrc"

for _fn in extract_real_tag count_secret_scan_workflows grep_x toolchain_note fold_makefile spec_field driven_symbol driven_keys implemented_test; do
  _src="$(sed -n "/^${_fn}() {/,/^}/p" "$PROBE")"
  _first="$(sed -n "/^${_fn}() {/{p;q;}" "$PROBE")"
  case "$_first" in *"}"*) _src="$_first" ;; esac
  eval "$_src"
  declare -F "$_fn" >/dev/null || {
    echo "selftest: could not source $_fn from $PROBE -- it was renamed or reshaped" >&2
    fails=$((fails+1))
  }
done

# extract_real_tag: the CHOSEN build tag, skipping the two reserved words.
_tagdir="$(mktemp -d)"
printf "//go:build candidate\npackage x\n" > "${_tagdir}/a_test.go"
printf "//go:build ignore\npackage x\n"    > "${_tagdir}/b_test.go"
printf "//go:build e2e\npackage x\n"       > "${_tagdir}/c_test.go"
check "extract_real_tag skips candidate and ignore" "e2e" "$(extract_real_tag "$_tagdir")"

# A tag with a digit or a dot is a REAL tag. The character class was
# [A-Za-z_]* once and truncated `go1.26` to `go`; this is the case that would
# have caught it.
_tagdir2="$(mktemp -d)"
printf "//go:build integration_v2\npackage x\n" > "${_tagdir2}/a_test.go"
check "extract_real_tag keeps digits" "integration_v2" "$(extract_real_tag "$_tagdir2")"

# And nothing to find is EMPTY, not the first line of noise.
_tagdir3="$(mktemp -d)"
printf "package x\n" > "${_tagdir3}/a_test.go"
check_empty "extract_real_tag finds nothing when there is no build tag" "$(extract_real_tag "$_tagdir3")"

# count_secret_scan_workflows: a MECHANISM, never a mention. Three files, one
# of which only names it in a comment.
_wfdir="$(mktemp -d)"
printf "jobs:\n  build:\n    steps:\n      - uses: org/secret-scan@v1\n"    > "${_wfdir}/a.yaml"
printf "jobs:\n  secret-scan:\n    runs-on: ubuntu-latest\n"                > "${_wfdir}/b.yaml"
printf "jobs:\n  build:\n    steps:\n      # secret-scan runs elsewhere\n"  > "${_wfdir}/c.yaml"
# THE SHAPE THE DEFECT ACTUALLY NEEDS: a trailing comment on a REAL `uses:`
# line. The `c.yaml` fixture puts the comment on its OWN line, which the `^`
# anchor already rejects -- so it passed for a reason the defect does not depend
# on. Reported by agatticelli on kraken-marketdata#11.
printf "jobs:\n  build:\n    steps:\n      - uses: actions/checkout@v4  # secret-scan runs in ci.yaml, not here\n" > "${_wfdir}/d.yaml"
check "count_secret_scan_workflows counts mechanisms, not mentions" "2" \
  "$(count_secret_scan_workflows "$_wfdir")"

# spec_field OWES TWO OBLIGATIONS, AND THE FIRST FIX MET ONE.
# It both SCANS lines for `^key:` and RETURNS a value, so it has to read the
# body when the block belongs to the requested key AND skip it when it does
# not. Only the first landed: a folded retention_policy whose prose spelled
# `deletion_mechanism: TBD` returned TBD, over a real value two lines below.
# Found by agatticelli on kraken-marketdata#11. The second case is the control.
_sfp="$(mktemp -d)"
printf 'data_lifecycle:\n  retention_policy: >\n    We keep nothing.\n    deletion_mechanism: TBD\n  deletion_mechanism: no_subject_data\n' \
  > "${_sfp}/spec.yaml"
check "spec_field does not read a key out of ANOTHER key's block body" "no_subject_data" \
  "$(SPEC="${_sfp}/spec.yaml" spec_field data_lifecycle deletion_mechanism)"
check "spec_field reads the block that IS the requested key" "We keep nothing." \
  "$(SPEC="${_sfp}/spec.yaml" spec_field data_lifecycle retention_policy)"

# THE TWO CASES ABOVE OPEN THEIR BLOCK WITH A PLAIN LOWERCASE KEY, which the
# NARROW class matched too -- so they pin that spec_field skips a block at all,
# and pin nothing about WHICH block headers it recognises. Reverting the
# widening left the whole suite green. Reported by agatticelli.
#
# Each shape below defeated a different class: a leading digit, a slash, a
# quote, a two-digit indentation indicator, a trailing comment, whitespace in
# the key, and a colon INSIDE a quoted key -- the last three being why the key
# half stopped being a character class at all. An unrecognised header is not
# skipped, it is WALKED, so every one of these returned the prose `TBD` over
# the real value two lines below.
for _hdr in '2fa_notes: >' 'ops/notes: >' '"design notes": >' 'notes: >12' 'notes: > # why' "'notes': >" 'ops notes: >' '"a:b": >'; do
  printf 'data_lifecycle:\n  %s\n    We keep nothing.\n    deletion_mechanism: TBD\n  deletion_mechanism: no_subject_data\n' "$_hdr" \
    > "${_sfp}/spec.yaml"
  check "spec_field skips a block opened by '${_hdr}'" "no_subject_data" \
    "$(SPEC="${_sfp}/spec.yaml" spec_field data_lifecycle deletion_mechanism)"
done

# THE TWO DEFENCES THAT LIVED ONLY IN check-registries.sh. Sharing the walker
# was right, but `is_block_header`/`indent_of` carried neither the tab guard nor
# the comment strip -- so all four spec walkers inherited both holes at once
# instead of one of them having it. Reported by agatticelli.
#
# Axis 1, the tab: counting it as ONE character makes a tab-indented body
# measure narrower than its own header, the block ends early, and the prose is
# read as a declaration. Returned `ESTO-ES-PROSA` over the real value below.
printf 'scalability:\n  notes: |\n\tpartition_key: ESTO-ES-PROSA\n  partition_key: el-valor-real\n' \
  > "${_sfp}/spec.yaml"
check "spec_field: a tab-indented body stays inside the block" "el-valor-real" \
  "$(SPEC="${_sfp}/spec.yaml" spec_field scalability partition_key)"

# Axis 2, the trailing comment: `.*:` reaches a colon inside a `#`, so the line
# was eaten as a header and the real value disappeared -- spec_field returned
# EMPTY. The strip also has to reach the returned value, or the row compares a
# declaration against a string carrying its own annotation.
printf 'scalability:\n  partition_key: el-valor-real   # ver nota: |\n  notes: prose\n' \
  > "${_sfp}/spec.yaml"
check "spec_field: a trailing comment neither opens a block nor rides the value" "el-valor-real" \
  "$(SPEC="${_sfp}/spec.yaml" spec_field scalability partition_key)"

# AND THE CONTROL THE STRIP NEEDS: inside a block BODY a `#` is content and
# must survive. Stripping there would silently edit evidence text.
printf 'd:\n  notes: |\n    line # con hash\n' > "${_sfp}/spec.yaml"
check "spec_field: a block body keeps its own hash" "line # con hash" \
  "$(SPEC="${_sfp}/spec.yaml" spec_field d notes)"

# THE THREE SIBLINGS THAT WALKED BLOCK BODIES AS KEYS. `spec_field` learned to
# skip a block scalar; `driven_symbol`, `driven_keys` and `implemented_test`
# did not, and they read the same file. Measured before the shared library:
#
#   driven_symbol durable_outbox  ->  ESTO-ES-PROSA   (the real value,
#                                     store.OpenDurable, sits two lines below)
#   driven_keys                   ->  notes durable_outbox durable_outbox
#                                     (the real key listed TWICE, once from the
#                                     prose inside the block)
#
# This file records the same mistake five times for marker rows: one repaired
# while a sibling a few lines away keeps the bug. Reported by fd1az, who also
# named the shape of the fix -- share the walker instead of transcribing it.
printf 'driven:\n  notes: >\n    prose that imitates keys\n    durable_outbox: ESTO-ES-PROSA\n  durable_outbox: store.OpenDurable\nimplemented:\n  notes: >\n    effect_journal: PROSE\n  effect_journal: TestOutboxSurvivesRestart\n' \
  > "${_sfp}/spec.yaml"
check "driven_symbol does not read a key out of a block body" "store.OpenDurable" \
  "$(SPEC="${_sfp}/spec.yaml" driven_symbol durable_outbox)"
check "driven_keys does not list a key that only exists as prose" "notes durable_outbox" \
  "$(SPEC="${_sfp}/spec.yaml" driven_keys | tr '\n' ' ' | sed 's/ *$//')"
check "implemented_test does not read a test name out of a block body" "TestOutboxSurvivesRestart" \
  "$(SPEC="${_sfp}/spec.yaml" implemented_test effect_journal)"

# THE CONTROL THE WIDENING NEEDS: a plain `key: value` whose value merely
# CONTAINS an indicator must NOT be read as a header, or the widening would
# swallow the real key below it.
printf 'data_lifecycle:\n  retention_policy: see foo | bar\n  deletion_mechanism: no_subject_data\n' \
  > "${_sfp}/spec.yaml"
check "spec_field: a value containing a pipe does not open a block" "no_subject_data" \
  "$(SPEC="${_sfp}/spec.yaml" spec_field data_lifecycle deletion_mechanism)"
rm -rf "$_sfp"

# NOT-RE-VERIFIED HAD NO CASE, AND IT WAS CHECKED FIRST.
# `go test ./...` prints one line per package, so a sibling with no test files
# puts "[no test files]" in the same output as the `--- FAIL` that proves the
# mutation was caught. With the skip test first, a genuine detection was
# reported as NOT-RE-VERIFIED -- fail-closed, so nothing got through, but a
# correct red under the wrong reason is how a correct red gets argued away.
# Reported by agatticelli on kraken-marketdata#11. The second case is the
# control: an output with NO verdict at all must still be NOT-RE-VERIFIED.
check "a real FAIL outranks a sibling's [no test files]" "DETECTED" \
  "$(classify_mutation_result 'ok   example/other  [no test files]
--- FAIL: TestInvariant_X (0.01s)
FAIL example/pkg 0.02s')"
check "no verdict at all is still NOT-RE-VERIFIED" "NOT-RE-VERIFIED" \
  "$(classify_mutation_result 'ok   example/other  [no test files]')"

# grep_x: the same distinction, as a helper. A file whose ONLY match is inside
# a comment must not be returned.
_gxdir="$(mktemp -d)"
printf "# diff-cover is not wired here\n"        > "${_gxdir}/only-comment.yaml"
printf "run: bash scripts/diff-cover.sh\n"       > "${_gxdir}/real.yaml"
_gxhits="$(grep_x "diff-cover" "$_gxdir")"
check "grep_x returns the file with a real occurrence" "real.yaml" "$_gxhits"
if [[ "$_gxhits" == *only-comment.yaml* ]]; then
  echo "  FAIL grep_x returned a file whose only match is a comment: $_gxhits" >&2
  fails=$((fails+1))
else
  echo "  ok   grep_x does not return a comment-only match"
fi

# THE `--` BRANCH HAD NO CASE. `grep_x` eats leading `-` arguments as grep flags
# until it sees `--`, and no caller in the probe passes one -- so the branch was
# dead as far as this suite could tell, and a pattern that legitimately starts
# with a dash would have been swallowed as a flag. Reported by agatticelli.
#
# Both directions, because only the pair pins it: WITH `--` the dash-leading
# pattern is a pattern, and the `-i` before it is still honoured as a flag.
printf -- "-Xfrontend is set here\n" > "${_gxdir}/dashy.yaml"
printf -- "nothing to see\n"         > "${_gxdir}/plain.yaml"
_gxdash="$(grep_x -- "-Xfrontend" "$_gxdir")"
check "grep_x after -- treats a dash-leading pattern as a pattern" "dashy.yaml" "$_gxdash"
printf -- "-XFRONTEND in caps\n" > "${_gxdir}/caps.yaml"
_gxflag="$(grep_x -i -- "-Xfrontend" "$_gxdir" | tr '\n' ' ')"
case "$_gxflag" in
  *dashy.yaml*caps.yaml*|*caps.yaml*dashy.yaml*)
    echo "  ok   grep_x still honours a flag placed before --" ;;
  *)
    echo "  FAIL grep_x dropped a flag before --: $_gxflag" >&2
    fails=$((fails+1)) ;;
esac

# fold_makefile: a backslash continuation is ONE logical line. The fuzz
# reachability walk parses rules, and an unfolded continuation hides the
# prerequisites that follow it.
_mkdir="$(mktemp -d)"
printf "verify: lint \\\\\n\tfuzz\n\t@echo hi\n" > "${_mkdir}/Makefile"
# The property is that the continuation LANDS ON THE FIRST LINE, not that the
# whitespace is normalised -- sed joins the lines and keeps the tab, which is
# correct. My first expectation here was `verify: lint fuzz` and it failed
# against `verify: lint \tfuzz`: the assertion was wrong, not the code, and it
# is worth saying so rather than quietly relaxing it.
_folded="$(cd "$_mkdir" && fold_makefile | head -1)"
check "fold_makefile joins a backslash continuation" "fuzz" "$_folded"
check "the folded line still starts with the target" "verify:" "$_folded"
# The control: UNFOLDED, `fuzz` is on the second line, so the case above is
# measuring the fold and not the file.
_unfolded="$(cd "$_mkdir" && head -1 Makefile)"
if [[ "$_unfolded" == *fuzz* ]]; then
  echo "  FAIL the fixture does not need folding, so the case above proves nothing" >&2
  fails=$((fails+1))
else
  echo "  ok   the fixture's first line needs folding to reach fuzz"
fi

# toolchain_note: it must say WHICH toolchain ran, and warn when go.mod pins a
# different one -- the row that reports a vulnerability count depends on it.
_tcdir="$(mktemp -d)"
printf "module x\n\ngo 0.0.1\n" > "${_tcdir}/go.mod"
check "toolchain_note warns when go.mod pins another toolchain" "go.mod pins go0.0.1" \
  "$(cd "$_tcdir" && toolchain_note)"
# THE DENOMINATOR: THIS CASE COULD REPORT ok WITHOUT BUILDING ITS SCENARIO.
# The fixture's `go` line came from `$(go env GOVERSION)`. With no Go the
# substitution is empty, the line is a version-less `go `, toolchain_note's awk
# does not match it, and the case printed `ok` -- unable to tell
# quiet-because-the-pin-matches from quiet-because-there-is-no-pin. Reported by
# agatticelli. A case that cannot build its scenario has to say so, not pass.
_tcdir2="$(mktemp -d)"
_hostgo="$(go env GOVERSION 2>/dev/null | sed "s/^go//")"
if [[ -z "${_hostgo//[[:space:]]/}" ]]; then
  echo "  FAIL toolchain_note is quiet when the pin matches -- the fixture was never built:" >&2
  echo "       'go env GOVERSION' produced nothing. Install Go, or run this on CI." >&2
  fails=$((fails+1))
else
  printf "module x\n\ngo %s\n" "$_hostgo" > "${_tcdir2}/go.mod"
  _note="$(cd "$_tcdir2" && toolchain_note)"
  if [[ "$_note" == *"pins"* ]]; then
    echo "  FAIL toolchain_note cried wolf when the pin matches the running toolchain: $_note" >&2
    fails=$((fails+1))
  else
    echo "  ok   toolchain_note is quiet when the pin matches (go$_hostgo)"
  fi
fi


echo "non-vacuity selftest: start"

# THE VERDICT MUST BE THE MUTATED TEST'S, NOT A NEIGHBOUR'S. The classifier read
# `^(--- )?FAIL` anywhere, so a run where OUR test skipped and a SIBLING failed
# classified as DETECTED -- certifying an invariant never measured. Reported by
# fd1az on binance-marketdata#24. The call site knows which test it mutated, so
# it passes it and the FAIL has to name it. The control is our own test's FAIL:
# scoping must not stop it detecting.
check "a sibling's FAIL is not our verdict" "NOT-RE-VERIFIED" \
  "$(classify_mutation_result '--- SKIP: TestInvariant_Ours (0.00s)
--- FAIL: TestOther_Theirs (0.01s)
FAIL other/pkg 0.02s' TestInvariant_Ours)"
check "control: our own FAIL is still detected" "DETECTED" \
  "$(classify_mutation_result '--- FAIL: TestInvariant_Ours (0.01s)
FAIL our/pkg 0.02s' TestInvariant_Ours)"

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

# THE TRAP LINE ITSELF, not the probe's whole text.
#
# This was `check "..." "EXIT INT TERM" "$(cat "$PROBE")"`, and the note here
# defended it as a deliberate source assertion. The defence was about the wrong
# risk: the problem is not that it reads source instead of driving the trap, it
# is that it read THE WHOLE FILE, so any comment containing the words satisfied
# it. Measured by fd1az on bitgo-marketdata: weakening the trap to `EXIT` alone,
# leaving the phrase in a comment, kept the case printing ok -- 24/24, exit 0.
#
# Driving it really would mean killing the probe mid-mutation and risking a
# production file left mutated, so extracting the trap LINE and asserting on its
# signal list is the strongest form available that costs nothing. A trap that
# loses INT or TERM now fails here; a comment cannot supply either.
trap_line=$(grep -m1 -E "^[[:space:]]*trap[[:space:]]+'restore_mutations" "$PROBE" || true)
if [[ -z "$trap_line" ]]; then
  echo "  FAIL the restore trap is not installed at all (no 'trap ... restore_mutations' line)" >&2
  fails=$((fails+1))
else
  trap_signals="${trap_line##*\'}"
  for sig in EXIT INT TERM; do
    check "the restore trap catches $sig" "$sig" "$trap_signals"
  done
fi

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

