#!/usr/bin/env bash
# run-once-selftest.sh -- scripts/run-once.sh records one line per run and vouches for a
# recorded result ONLY when the id, the command string, the tree identity and the run id all
# match a well-formed line, with no conflicting duplicate.
# provenance: candidate; ttl: 2027-02-27; pinning: true
# Hermetic: a scratch git repo holding a copy of the script; no network, no repo suite re-run.
# The Makefile `selftests` wiring (records each suite, REQUIRED_SELFTESTS guard) is driven here
# too, over a scratch copy of the real Makefile with its variables overridden on the command line.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
unset EVIDENCE_RESULTS EVIDENCE_RUN_ID EVIDENCE_MAX_AGE
T=$(mktemp -d) || exit 2
trap 'rm -rf "$T"' EXIT
S="$T/repo"; mkdir -p "$S/scripts" "$T/out"
cp "$root/scripts/run-once.sh" "$S/scripts/run-once.sh"
mkdir -p "$S/.prod"; echo keep > "$S/.prod/keep"
git -C "$S" init -q . && git -C "$S" add -A && git -C "$S" -c user.email=t@t -c user.name=t commit -q -m base || exit 2
echo "tracked" > "$S/tracked.txt"; git -C "$S" add tracked.txt && git -C "$S" -c user.email=t@t -c user.name=t commit -q -m tracked

CASES=0; FAILED=0
check() { CASES=$((CASES+1)); if [ "$2" = "$3" ]; then printf '  ok   %-70s %s\n' "$1" "$3"
  else printf '  FAIL %-70s expected=%s actual=%s\n' "$1" "$2" "$3"; FAILED=$((FAILED+1)); fi; }
ro()  { (cd "$S" && EVIDENCE_RESULTS="$RES" EVIDENCE_RUN_ID="${RUN:-r1}" bash scripts/run-once.sh "$@"); }
res() { ro resolve "$1" "$2" | cut -f1,2 | tr '\t' ' '; }       # kind + (rc | reason)
res2() { res "$1" "$2" | awk '{print $1 " " $2}'; }            # kind + first word of the reason
kind() { ro resolve "$1" "$2" | cut -f1; }
fresh() { RES="$T/res-$1.tsv"; RUN=r1; rm -f "$RES"; }
commit() { git -C "$S" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "$1"; }

# ---- recording ------------------------------------------------------------------------------
fresh rec
ro g1 -- bash -c 'echo hello; echo "12 ok, 0 failed"' >"$T/out/o1" 2>&1; rc=$?
check "run: exit code of the command is passed through (0)" 0 "$rc"
check "run: the command's output is shown (tee)" 2 "$(wc -l <"$T/out/o1" | tr -d ' ')"
check "run: exactly one line is recorded" 1 "$(wc -l <"$RES" | tr -d ' ')"
check "run: the line has twelve tab-separated columns" 12 "$(awk -F'\t' '{print NF}' "$RES")"
check "run: column 1 is the format tag, column 2 the id" "v1 g1" "$(cut -f1,2 "$RES" | tr '\t' ' ')"
check "run: the evidence column is the last unindented line" "12 ok, 0 failed" "$(cut -f12 "$RES")"
check "run: tree identity is HEAD plus clean" "$(git -C "$S" rev-parse HEAD)+clean" "$(cut -f9 "$RES")"
ro g2 -- bash -c 'exit 3' >/dev/null 2>&1; check "run: a failing command's exit code is passed through (3)" 3 "$?"
check "run: the failure is recorded with its exit code" 3 "$(awk -F'\t' '$2=="g2"{print $4}' "$RES")"
q=$(ro --quiet g3 -- bash -c 'echo noise'); check "run --quiet: nothing on stdout on success" "" "$q"
q=$(ro --quiet g4 -- bash -c 'echo l1; echo l2; exit 1'); check "run --quiet: the tail is printed on failure" "l1 l2" "$(echo $q)"
ro g5 -- bash -c 'exit 0' >/dev/null 2>&1
check "run: a command with no output still records a verdict-from-exit-code evidence" "(gate produced no output; verdict from exit code 0 alone)" "$(awk -F'\t' '$2=="g5"{print $12}' "$RES")"
ro 'bad id' -- true >/dev/null 2>&1; check "run: a bad id is refused (2)" 2 "$?"
ro g6 true >/dev/null 2>&1; check "run: a missing -- is refused (2)" 2 "$?"
ro g7 -- >/dev/null 2>&1; check "run: no command is refused (2)" 2 "$?"
ro g8 -- bash -c 'printf "a\tb\n"' >/dev/null 2>&1; check "run: a plain command whose OUTPUT has a tab is recorded (1 line)" 1 "$(grep -c "^v1.g8" "$RES")"
ro g9 -- printf $'a\tb' >/dev/null 2>&1; check "run: a command string with a TAB is refused (2)" 2 "$?"

# ---- attest: the match rules ----------------------------------------------------------------
fresh att
ro a1 -- bash -c 'echo summary-one' >/dev/null 2>&1
CMD='bash -c echo summary-one'
check "resolve: same id + command + tree + run -> attested rc 0" "attested 0" "$(res a1 "$CMD")"
check "resolve: the attested line carries the evidence" "summary-one" "$(ro resolve a1 "$CMD" | cut -f7)"
check "resolve: the attested line names its line number" 1 "$(ro resolve a1 "$CMD" | cut -f3)"
check "resolve: another id -> miss" "miss" "$(kind a2 "$CMD")"
check "resolve: command string differs -> miss" "miss" "$(kind a1 "$CMD x")"
RUN=r2; check "resolve: another run id -> miss" "miss" "$(kind a1 "$CMD")"; RUN=r1
check "resolve: too old (max age -1) -> miss" "miss" "$(cd "$S" && EVIDENCE_MAX_AGE=-1 EVIDENCE_RESULTS="$RES" EVIDENCE_RUN_ID=r1 bash scripts/run-once.sh resolve a1 "$CMD" | cut -f1)"
echo changed >> "$S/tracked.txt"
check "resolve: tree went from clean to dirty -> miss" "miss" "$(kind a1 "$CMD")"
ro a3 -- bash -c 'echo dirty-run' >/dev/null 2>&1
check "resolve: a line recorded on the dirty tree is attested on that same dirty tree" "attested" "$(kind a3 'bash -c echo dirty-run')"
echo changed-again >> "$S/tracked.txt"
check "resolve: the dirty content changed since -> miss" "miss" "$(kind a3 'bash -c echo dirty-run')"
git -C "$S" checkout -q -- tracked.txt
check "resolve: tree back to clean -> the clean line is attested again" "attested" "$(kind a1 "$CMD")"
echo new > "$S/untracked.txt"
check "resolve: an untracked file makes the tree dirty -> miss" "miss" "$(kind a1 "$CMD")"
rm -f "$S/untracked.txt"
commit "next"
check "resolve: another HEAD -> miss" "miss" "$(kind a1 "$CMD")"
fresh att2
ro a1 -- bash -c 'echo summary-one' >/dev/null 2>&1
mkdir -p "$S/.evidence" "$S/.prod/evidence"; : > "$S/.evidence/x"; : > "$S/.prod/evidence/x.json"
check "resolve: .evidence and .prod/evidence do not dirty the tree" "attested" "$(kind a1 "$CMD")"

# ---- attest: the file itself is not trustworthy ---------------------------------------------
fresh bad
check "resolve: no results file -> miss no-results-file" "miss no-results-file" "$(res a1 "$CMD")"
: > "$RES"
check "resolve: an empty results file -> miss empty-results-file" "miss empty-results-file" "$(res a1 "$CMD")"
printf '\n\n' > "$RES"
check "resolve: a file of blank lines -> miss empty-results-file" "miss empty-results-file" "$(res a1 "$CMD")"
ro a1 -- bash -c 'echo summary-one' >/dev/null 2>&1
good=$(cat "$RES")
printf '%s\n' "garbage line" >> "$RES"
check "resolve: a malformed line anywhere voids the WHOLE file" "miss malformed-results-file" "$(res2 a1 "$CMD")"
n=0
for mut in '$1="v2"' '$4="zero"' '$6="nothex"' '$9="notatree"' '$10=""' '$13="extra"' 'NF=11'; do
  n=$((n+1)); printf '%s\n' "$good" | awk -F'\t' -v OFS='\t' "{ $mut; print }" > "$RES"
  check "resolve: malformed variant $n ($mut) is never attested" "miss malformed-results-file" "$(res2 a1 "$CMD")"
done
printf '%s\n' "$good" > "$RES"
check "resolve: the unmodified line is attested (the mutations above were real)" "attested" "$(kind a1 "$CMD")"

# ---- attest: failures and duplicates --------------------------------------------------------
fresh dup
ro --as "bash gates/x.sh" a1 -- false >/dev/null 2>&1
check "resolve: a recorded FAILURE is attested as rc 1, never as a pass" "attested 1" "$(res a1 "bash gates/x.sh")"
ro --as "bash gates/x.sh" a1 -- true >/dev/null 2>&1
check "resolve: conflicting outcomes for one id -> miss" "miss conflicting-lines-for-this-id" "$(res a1 "bash gates/x.sh")"
fresh dup2
ro --as "bash gates/x.sh" a1 -- true >/dev/null 2>&1; ro --as "bash gates/x.sh" a1 -- true >/dev/null 2>&1
check "resolve: a duplicate with the SAME outcome is attested" "attested" "$(kind a1 "bash gates/x.sh")"
check "resolve: ...and names the last line" 2 "$(ro resolve a1 "bash gates/x.sh" | cut -f3)"
ro --as "bash gates/y.sh" a1 -- false >/dev/null 2>&1
check "resolve: a failing line under ANOTHER command string does not conflict" "attested 0" "$(res a1 "bash gates/x.sh")"

# ---- the tree changing under the command ----------------------------------------------------
fresh uns
ro u1 -- bash -c 'echo made > unstable-made.txt' >/dev/null 2>&1
check "run: a command that changes the tree is recorded unstable" 1 "$(cut -f9 "$RES" | grep -c '+unstable$')"
check "resolve: an unstable line is never attested" "miss" "$(kind u1 "bash -c echo made > unstable-made.txt")"
rm -f "$S/unstable-made.txt"

# ---- the command string is compared literally (no awk escape processing) --------------------
fresh esc
ro e1 -- bash -c 'printf "%s" "a\\nb"' >/dev/null 2>&1
check "resolve: a command with backslashes matches itself exactly" "attested" "$(kind e1 'bash -c printf "%s" "a\\nb"')"
ro --as 'cmd with spaces' e2 -- true >/dev/null 2>&1
check "run --as: the label is what is recorded and matched" "attested" "$(kind e2 'cmd with spaces')"
check "run --as: the real argv is NOT what is matched" "miss" "$(kind e2 'true')"

# ---- counts ---------------------------------------------------------------------------------
sum() { printf '%s\n' "$1" | bash "$S/scripts/run-once.sh" count; }
mbcount() { printf '%s\n' "$1" | grep -oE '[0-9]+ (ok|case)' | tail -1 | grep -oE '^[0-9]+'; }
check "mutation-baseline.sh still carries the count expression this pins" "1" "$(grep -cF "grep -oE '[0-9]+ (ok|case)'" "$root/scripts/mutation-baseline.sh" | awk '{print ($1 >= 1)}')"
for s in '12 ok, 0 failed' '60 case(s), every verdict was right' 'probe-self gate selftest: 29 ok' $'noise\n7 ok\ntrailer 3 case(s) done'; do
  check "count: run-once and mutation-baseline agree on [${s//$'\n'/ | }]" "$(mbcount "$s")" "$(sum "$s")"
done
check "count: a summary with no count exits 1" 1 "$(printf 'nothing\n' | bash "$S/scripts/run-once.sh" count >/dev/null; echo $?)"
fresh cnt
printf '#!/usr/bin/env bash\necho "fake suite"; echo "17 case(s) passed"\n' > "$T/fake-selftest.sh"
ro --quiet --count "selftest:fake-selftest.sh" -- bash "$T/fake-selftest.sh" >/dev/null 2>&1
direct=$(mbcount "$(bash "$T/fake-selftest.sh")")
check "counts: the count from the single pass equals the count from running the suite" "$direct" "$(ro counts | cut -f3)"
check "counts: the recorded command string is carried for the reader to compare" "bash $T/fake-selftest.sh" "$(ro counts | cut -f2)"
ro --count "selftest:fail-selftest.sh" -- bash -c 'echo "9 ok"; exit 1' >/dev/null 2>&1
check "counts: a FAILING suite's count is not offered" 1 "$(ro counts | wc -l | tr -d ' ')"
cp "$RES" "$T/res-cnt.good"
awk -F'\t' -v OFS='\t' '{$9="0000000000000000000000000000000000000000+clean"; print}' "$T/res-cnt.good" > "$RES"
check "counts: a line with a tampered tree identity (well-formed, other HEAD) is not trusted" 0 "$(ro counts | wc -l | tr -d ' ')"
cp "$T/res-cnt.good" "$RES"; RUN=r9
check "counts: a line from another run is not trusted" 0 "$(ro counts | wc -l | tr -d ' ')"; RUN=r1
check "counts: the untampered file offers the suite (the cases above were real)" 1 "$(ro counts | grep -c 'fake-selftest.sh')"
fresh cnt2
ro --quiet --count --as C s1 -- bash -c 'echo "17 ok"' >/dev/null 2>&1; ro --quiet --count --as C s1 -- bash -c 'echo "17 ok"' >/dev/null 2>&1
check "counts: the same count twice is offered once" 1 "$(ro counts | wc -l | tr -d ' ')"
ro --quiet --count --as C s1 -- bash -c 'echo "18 ok"' >/dev/null 2>&1
check "counts: two different counts for one suite and command -> not offered" 0 "$(ro counts | wc -l | tr -d ' ')"
printf 'garbage\n' >> "$RES"
check "counts: a malformed file offers nothing" 0 "$(ro counts | wc -l | tr -d ' ')"

# ---- the Makefile wiring: `selftests` records each suite and guards the required list -------
M="$T/mk"; mkdir -p "$M/scripts" "$M/probes/tests" "$M/scripts/tests"
cp "$root/scripts/run-once.sh" "$M/scripts/run-once.sh"; cp "$root/Makefile" "$M/Makefile"
printf '#!/usr/bin/env bash\necho "3 ok, 0 failed"\n' > "$M/probes/a-selftest.sh"
printf '#!/usr/bin/env bash\necho "5 case(s) passed"\n' > "$M/probes/tests/b-selftest.sh"
git -C "$M" init -q . && git -C "$M" add -A && git -C "$M" -c user.email=t@t -c user.name=t commit -q -m base
mk() { (cd "$M" && EVIDENCE_RUN_ID=m1 make --no-print-directory selftests PROBES=probes TEMPLATE_SELFTESTS= REQUIRED_SELFTESTS="$1" 2>&1); }
mk "probes/a-selftest.sh probes/tests/b-selftest.sh" > "$T/out/mk1"
check "make selftests: runs the fake suites and ends 'selftests: 2 passed'" "selftests: 2 passed" "$(tail -1 "$T/out/mk1")"
check "make selftests: records the whole run under the command string evidence attests to" "attested" "$(cd "$M" && EVIDENCE_RUN_ID=m1 bash scripts/run-once.sh resolve probe-selftests 'make --no-print-directory selftests' | cut -f1)"
check "make selftests: records each suite with its case count" "probes/a-selftest.sh 3|probes/tests/b-selftest.sh 5" "$(cd "$M" && EVIDENCE_RUN_ID=m1 bash scripts/run-once.sh counts | sed 's/^selftest://' | awk -F'\t' '{printf "%s%s %s", sep, $1, $3; sep="|"}')"
check "make selftests: the per-suite lines are ones mutation-baseline can consume (id and command agree)" "2" "$(cd "$M" && EVIDENCE_RUN_ID=m1 bash scripts/run-once.sh counts | awk -F'\t' '{id=$1; sub(/^selftest:/,"",id); if ($2 == "bash " id) n++} END{print n+0}')"
mk "probes/a-selftest.sh probes/tests/gone-selftest.sh" > "$T/out/mk2"; echo $? > "$T/out/mk2rc"
check "make selftests: a REQUIRED suite that does not exist -> exit 2 naming it" "2 1" "$(cat "$T/out/mk2rc") $(grep -c 'gone-selftest.sh is missing' "$T/out/mk2")"
printf '#!/usr/bin/env bash\necho "1 ok"\n' > "$M/odd-selftest.sh"
mk "probes/a-selftest.sh odd-selftest.sh" > "$T/out/mk3"; echo $? > "$T/out/mk3rc"
check "make selftests: a REQUIRED suite outside the glob -> exit 2 'did not run it'" "2 1" "$(cat "$T/out/mk3rc") $(grep -c 'odd-selftest.sh exists but the glob did not run it' "$T/out/mk3")"
printf '#!/usr/bin/env bash\necho "boom"; echo "1 ok"; exit 1\n' > "$M/probes/c-selftest.sh"
mk "probes/a-selftest.sh" > "$T/out/mk4"; echo $? > "$T/out/mk4rc"
check "make selftests: a failing suite -> non-zero exit" 1 "$([ "$(cat "$T/out/mk4rc")" != 0 ] && echo 1 || echo 0)"
check "make selftests: ...and its output tail is printed" 1 "$(grep -c '^boom$' "$T/out/mk4")"
check "make selftests: ...and the failure is recorded (attested, non-zero) for the whole run" "attested 1" "$(cd "$M" && EVIDENCE_RUN_ID=m1 bash scripts/run-once.sh resolve probe-selftests 'make --no-print-directory selftests' | cut -f1,2 | awk '{print $1 " " ($2 != 0)}')"

if (( FAILED > 0 )); then echo "run-once selftest: $FAILED of $CASES case(s) FAILED"; exit 1; fi
echo "run-once selftest: $CASES case(s) passed"
