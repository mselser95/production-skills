#!/usr/bin/env bash
# evidence-record-selftest.sh -- scripts/evidence-record.sh RUNS the gates (`--run`, one at a time, through run-once.sh,
# in a clean environment) and, in `--attest`, takes a gate from the run-once results file ONLY for a same-id,
# same-command, same-tree, same-run, same-contract well-formed line, otherwise executes it, and says which in the record;
# a recorded failure fails the record; `probe-selftests` is attested only from per-suite lines of the same run.
# The results file is an ACCIDENT guard, not a tamper guard (the trust model in the headers): the "accident-class" cases
# below leak something into the caller's environment by accident (a BASH_ENV, exported functions, aliases, SHELLOPTS,
# gate switches) and require the gate to FAIL on its own, with no attested PASS. A deliberate edit of a tracked file is
# out of scope and is not tested.
# provenance: candidate; ttl: 2027-02-27; pinning: true
# Hermetic: fake gates are tiny scripts in scratch git repos; the GATES / suite arrays are replaced in a scratch COPY of
# the script, everything else in it is the real code. Cost: a recorder run is dozens of processes, so every scenario that
# only needs a different RESULTS FILE copies one recorded file and edits a column (the matching rules themselves are
# pinned one by one in run-once-selftest.sh), and cases that share a fixture share a scratch repo.
# Usage: evidence-record-selftest.sh [--only hostile]   (--only runs just the accident-class cases)
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
unset EVIDENCE_RESULTS EVIDENCE_RUN_ID EVIDENCE_MAX_AGE MAKEFLAGS MFLAGS EVIDENCE_CLEAN_ENV
ONLY=""; [[ "${1:-}" == --only ]] && ONLY="${2:-}"
T=$(mktemp -d) || exit 2
trap 'rm -rf "$T"' EXIT
LOG="$T/exec.log"

CASES=0; FAILED=0
check() { CASES=$((CASES+1)); if [ "$2" = "$3" ]; then printf '  ok   %-72s %s\n' "$1" "$3"
  else printf '  FAIL %-72s expected=%s actual=%s\n' "$1" "$2" "$3"; FAILED=$((FAILED+1)); fi; }
finish() { echo "$((CASES-FAILED)) ok, $FAILED failed"; (( FAILED == 0 )); exit $?; }

# mkrec <dest>: the REAL evidence-record.sh with its arrays replaced by R_GATES, R_SUITE_GLOBS,
# R_SUITE_TEMPLATE, R_SUITE_REQUIRED (multi-line bodies) and R_PRE_IDS / R_POST_IDS / R_AGG_IDS (words).
mkrec() {
  awk '
    /^(GATES|SUITE_GLOBS|SUITE_TEMPLATE|SUITE_REQUIRED)=\(/ { match($0, /^[A-Z_]+/); n = substr($0, 1, RLENGTH); print n "=("; t = ENVIRON["R_" n]; if (t != "") print t; print ")"; skip = 1; next }
    skip { if ($0 ~ /^\)/) skip = 0; next }
    /^(PRE_IDS|POST_IDS|AGG_IDS)=\(/ { match($0, /^[A-Z_]+/); n = substr($0, 1, RLENGTH); print n "=(" ENVIRON["R_" n] ")"; next }
    { print }' "$root/scripts/evidence-record.sh" > "$1"
}
# build <dir> <GATES body lines...>: scratch repo with the REAL scripts and fake gates that log each execution
build() {
  local d="$1"; shift
  mkdir -p "$d/scripts" "$d/gates" "$d/.prod"; echo keep > "$d/.prod/keep"
  cp "$root/scripts/run-once.sh" "$d/scripts/run-once.sh"
  R_GATES=$(printf '  %s\n' "$@") mkrec "$d/scripts/evidence-record.sh"
  local g
  for g in one two; do
    printf '#!/usr/bin/env bash\necho "%s" >> "%s"\necho "ok-%s summary"\nrc=0; [ -f gates/%s.rc ] && read -r rc < gates/%s.rc\nexit "$rc"\n' "$g" "$LOG" "$g" "$g" "$g" > "$d/gates/$g.sh"
  done
  printf '#!/usr/bin/env bash\necho bad >> "%s"\necho "bad summary"\nexit 1\n' "$LOG" > "$d/gates/bad.sh"
  echo "tracked" > "$d/tracked.txt"
  git -C "$d" init -q . && printf 'gates/*.rc\ngates/dump.out\nscripts/*-ignored\n' >> "$d/.git/info/exclude" && git -C "$d" add -A && git -C "$d" -c user.email=t@t -c user.name=t commit -q -m base
}
# pure-bash helpers (no process per call): counts over the last record REC, lines of the exec log, order of gates run
REC=""
rec_load() { REC=$(cat "$1"/.prod/evidence/*.json 2>/dev/null); }
nrec() { local s="$REC" n=0; while [[ "$s" == *"$1"* ]]; do s=${s#*"$1"}; n=$((n+1)); done; echo "$n"; }
execs() { local n=0 l; while IFS= read -r l; do n=$((n+1)); done <"$LOG" 2>/dev/null; echo "$n"; }
order() { local o="" l; while IFS= read -r l; do o+="${o:+ }$l"; done <"$LOG" 2>/dev/null; echo "$o"; }
present() { [ -e "$1" ] && echo present || echo absent; }
fresh() { RES="$T/res-$1.tsv"; RUN=r1; rm -f "$RES"; : > "$LOG"; }
# er [dir=$S] args: the recorder in a repo with the run id and results file of the case; loads REC
erd() { local d="$1"; shift; (cd "$d" && rm -f .prod/evidence/*.json && EVIDENCE_RESULTS="$RES" EVIDENCE_RUN_ID="${RUN:-r1}" bash scripts/evidence-record.sh "$@"); local rc=$?; rec_load "$d"; return $rc; }
rod() { local d="$1"; shift; (cd "$d" && EVIDENCE_RESULTS="$RES" EVIDENCE_RUN_ID="${RUN:-r1}" bash scripts/run-once.sh "$@"); }
# from <name> <master results file>: a fresh results file for a scenario, copied from a recorded master
from() { RES="$T/res-$1.tsv"; cp "$2" "$RES"; RUN=r1; : > "$LOG"; }
# colset <file> <id> <col> <value>: edit one column of the line of an id (hand-made variants of a recorded line)
colset() { awk -F'\t' -v OFS='\t' -v id="$2" -v c="$3" -v v="$4" '$2 == id { $c = v } { print }' "$1" > "$1.n" && mv "$1.n" "$1"; }

# ---- the headers state the trust model, and the clean start is the first code of both scripts ---------------------
tm() { sed -n '/^# TRUST MODEL/,/^#$/p' "$1"; }
check "header: the trust model says it is an accident guard, not a tamper guard (evidence-record.sh)" 1 "$(grep -c 'It is an accident guard, not a tamper guard' "$root/scripts/evidence-record.sh")"
check "header: ...and the same sentence stands in run-once.sh" 1 "$(grep -c 'It is an accident guard, not a tamper guard' "$root/scripts/run-once.sh")"
check "header: the two trust-model paragraphs are identical, word for word" "$(tm "$root/scripts/run-once.sh")" "$(tm "$root/scripts/evidence-record.sh")"
check "header: no claim of resistance to a hostile Makefile or caller is left in either script" 0 "$(grep -ciE 'whatever Makefile|out of the trust path|same-job tampering|whoever calls this script' "$root/scripts/evidence-record.sh" "$root/scripts/run-once.sh" | awk -F: '{s+=$NF} END{print s+0}')"
cs() { sed -n '/^# CLEAN START/,/^\\unset -v _cs_al _cs_fn/p' "$1"; }
check "clean start: the block is byte-identical in both scripts" "$(cs "$root/scripts/run-once.sh")" "$(cs "$root/scripts/evidence-record.sh")"
for f in run-once evidence-record; do
  first=$(sed -n '/^# ---- end of header/,$p' "$root/scripts/$f.sh" | grep -vE '^[[:space:]]*(#|$)' | head -3 | awk '{print $1}' | tr '\n' '|')
  check "clean start: the FIRST executable lines of $f.sh are the PS4 line, POSIXLY_CORRECT=1, then \\unset -f" '>/dev/null"${_:$((PS4=0)):0}"|POSIXLY_CORRECT=1|\unset|' "$first"
done

# ---- accident-class cases: something leaked from the caller's environment must never weaken a gate -----------------
# real.sh FAILS unless SKIP reaches it; it dumps what it sees. Every case runs `--run g-real` with NO run id
# (nothing is recorded) and requires: the gate ran once, failed ON ITS OWN (exit 1, its own output), never saw SKIP.
SE="$T/repoe"; build "$SE" '"g-real|bash gates/real.sh"'
printf '#!/usr/bin/env bash\necho real >> "%s"\n{ env | sort; echo "TYPE_ENV=$(type -t env)"; echo "GLOB=$(echo gates/*.sh)"; echo "SET=$-"; } > gates/dump.out\n[ -n "${SKIP:-}" ] && exit 0\necho real-gate-fails\nexit 1\n' "$LOG" > "$SE/gates/real.sh"
printf 'export SKIP=1\n' > "$T/ba.sh"
cat > "$T/bb.sh" <<'BB'
export SKIP=1
env() { /usr/bin/env SKIP=1 "$@"; }
unset() { return 0; }
exec() { return 0; }
command() { builtin command "$@"; }
builtin() { return 0; }
printf() { return 0; }
git() { return 0; }
test() { return 0; }
'['() { return 0; }
echo() { return 0; }
cat() { return 0; }
date() { return 0; }
BB
cat > "$T/bc.sh" <<'BC'
shopt -s expand_aliases
for _n in env unset exec command builtin printf git test '[' echo cat date set export eval trap unalias alias declare shift compgen; do alias "$_n=true"; done
alias unset='SKIP=1 true'
export SKIP=1
BC
printf '#!/usr/bin/env bash\nexport EVIDENCE_CLEAN_ENV=1\nunset() { :; }\nenv() { command env SKIP=1 "$@"; }\nexec() { return 0; }\n' > "$SE/benv.sh"
git -C "$SE" add -A; git -C "$SE" -c user.email=t@t -c user.name=t commit -q -m benv
dumpseen() { local n=0 l; while IFS= read -r l; do [[ "$l" == "$1="* ]] && n=$((n+1)); done <"$SE/gates/dump.out" 2>/dev/null; echo "$n"; }
# hostile <name> <command...>: run `<command...> bash scripts/evidence-record.sh --run g-real` in the repo, WITH a run id
# (so the recorder also uses git, date, cat... and a shadowed one would show) and require exactly one recorded line, exit 1
hostile() {
  local name="$1" rc; shift
  : > "$LOG"; rm -f "$SE/gates/dump.out" "$SE/pwned" "$T/hres.tsv"
  (cd "$SE" && EVIDENCE_RUN_ID=r1 EVIDENCE_RESULTS="$T/hres.tsv" "$@" bash scripts/evidence-record.sh --run g-real >"$T/ho" 2>&1); rc=$?
  check "accident-class: $name -> the gate fails on its own (1), ran once, never saw SKIP, nothing pwned, one well-formed line recorded (exit 1)" "1 1 1 0 absent 1 14ok" "$rc $(execs) $(grep -c 'FAIL  g-real (exit 1)' "$T/ho") $(dumpseen SKIP) $(present "$SE/pwned") $(cut -f4 "$T/hres.tsv" 2>/dev/null | tr '\n' ' ' | sed 's/ $//') $(awk -F'\t' '{ print NF ($9 ~ /^[0-9a-f]+\+(clean|dirty-[0-9a-f]+)$/ ? "ok" : "bad") }' "$T/hres.tsv" 2>/dev/null)"
}
hostile "BASH_ENV file exports SKIP=1" env BASH_ENV="$T/ba.sh"
hostile "BASH_ENV defines functions env unset exec command builtin printf git test [ echo cat date" env BASH_ENV="$T/bb.sh"
hostile "BASH_ENV turns on expand_aliases and aliases the same names" env BASH_ENV="$T/bc.sh"
hostile "exported functions env unset exec printf echo git cat date from a bash parent" bash -c 'env() { /usr/bin/env SKIP=1 "$@"; }; unset() { return 0; }; exec() { return 0; }; printf() { return 0; }; echo() { return 0; }; git() { return 1; }; cat() { return 0; }; date() { return 0; }; export -f env unset exec printf echo git cat date; "$@"' x
hostile "raw BASH_FUNC_env%% / unset%% / exec%% / printf%% / git%% in the environment" env 'BASH_FUNC_env%%=() { /usr/bin/env SKIP=1 "$@"; }' 'BASH_FUNC_unset%%=() { return 0; }' 'BASH_FUNC_exec%%=() { return 0; }' 'BASH_FUNC_printf%%=() { return 0; }' 'BASH_FUNC_git%%=() { return 1; }'
hostile "the old EVIDENCE_CLEAN_ENV=1 marker plus SKIP=1 has no effect" env EVIDENCE_CLEAN_ENV=1 SKIP=1
hostile "the old EVIDENCE_CLEAN_ENV=1 marker together with a BASH_ENV of functions is not trusted either" env EVIDENCE_CLEAN_ENV=1 SKIP=1 BASH_ENV="$T/bb.sh"
hostile "SHELLOPTS=xtrace with PS4=\$(touch pwned): the command substitution in PS4 never runs" env SHELLOPTS=xtrace 'PS4=$(touch pwned)'
hostile "SHELLOPTS=noglob BASHOPTS=nullglob:extglob IFS=/ CDPATH=/ GLOBIGNORE=* POSIXLY_CORRECT=1 ENV=file" env SHELLOPTS=noglob BASHOPTS=nullglob:extglob IFS=/ CDPATH=/ GLOBIGNORE='*' POSIXLY_CORRECT=1 ENV="$T/ba.sh"
hostile "control: a plain caller (the gate still fails honestly)" env
check "control: the gate PASSES when SKIP does reach it (the failures above are the gate's own)" 0 "$(cd "$SE" && SKIP=1 bash gates/real.sh >/dev/null 2>&1; echo $?)"
(cd "$SE" && CLAUDE_CONFIG_DIR=/cfg EVIDENCE_RUN_ID=r1 EVIDENCE_RESULTS="$T/res-env.tsv" bash scripts/evidence-record.sh --run g-real >/dev/null 2>&1)
check "normal use: allowlisted names reach the gate, a glob still expands, bash is not in POSIX mode" "/cfg r1 1 0" "$(sed -n 's/^CLAUDE_CONFIG_DIR=//p' "$SE/gates/dump.out") $(sed -n 's/^EVIDENCE_RUN_ID=//p' "$SE/gates/dump.out") $(grep -c '^GLOB=.*gates/real.sh' "$SE/gates/dump.out") $(grep -c '^SET=.*p' "$SE/gates/dump.out")"
# the round-3 forgery, VERBATIM: a Makefile that exports BASH_ENV for `gates`, and a committed file that exports the old
# marker and defines functions `unset`, `env` and `exec`. A leaked BASH_ENV is an accident class; it now fails closed.
printf '.PHONY: gates evidence\ngates: export BASH_ENV := $(CURDIR)/benv.sh\ngates:\n\t@bash scripts/evidence-record.sh --run gates\nevidence:\n\t@bash scripts/evidence-record.sh --attest\n' > "$SE/Makefile"
fresh r3; (cd "$SE" && rm -f .prod/evidence/*.json && EVIDENCE_RUN_ID=r1 EVIDENCE_RESULTS="$RES" make -k --no-print-directory gates evidence >"$T/ho" 2>&1); rc=$?; rec_load "$SE"
check "accident-class: hostile BASH_ENV via make -> make fails, no PASS in the record, only exit 1 in the results" "1 0 1" "$([ "$rc" != 0 ] && echo 1 || echo "rc=$rc") $(nrec '"verdict": "PASS"') $(cut -f4 "$RES" | sort -u | tr '\n' ' ' | sed 's/ $//')"
# the same leak through every Makefile spelling, batched: leaked exports, a target-specific export, a GNUmakefile
{ printf '.PHONY: gates evidence\ngates: export SKIP := 1\ngates: export BASH_ENV := %s\nT := gates\n$(T): export EVIDENCE_CLEAN_ENV := 1\n$(eval RUN := env SKIP=1 bash scripts/run-once.sh)\nRUN += --quiet junk -- env SKIP=1 bash scripts/run-once.sh\n' "$T/ba.sh"
  printf 'gates:\n\t@bash scripts/evidence-record.sh --run gates\nevidence: export SKIP := 1\nevidence:\n\t@bash scripts/evidence-record.sh --attest\n'; } > "$SE/Makefile"
fresh fm; (cd "$SE" && rm -f .prod/evidence/*.json && EVIDENCE_RUN_ID=r1 EVIDENCE_RESULTS="$RES" make -k --no-print-directory gates evidence >"$T/ho" 2>&1); rc=$?; rec_load "$SE"
check "forgery via make: leaked exports (SKIP, BASH_ENV, marker, \$(eval), RUN +=) -> make fails, no PASS, only exit 1 recorded" "1 0 1" "$([ "$rc" != 0 ] && echo 1 || echo "rc=$rc") $(nrec '"verdict": "PASS"') $(cut -f4 "$RES" | sort -u | tr '\n' ' ' | sed 's/ $//')"
printf '.PHONY: gates evidence\ngates:\n\t@SKIP=1 bash scripts/evidence-record.sh --run gates\nevidence:\n\t@SKIP=1 bash scripts/evidence-record.sh --attest\n' > "$SE/GNUmakefile"
fresh fg; (cd "$SE" && rm -f .prod/evidence/*.json && EVIDENCE_RUN_ID=r1 EVIDENCE_RESULTS="$RES" make -k --no-print-directory gates evidence >"$T/ho" 2>&1); rc=$?; rec_load "$SE"
check "forgery via make: a committed GNUmakefile that passes SKIP=1 to the recorder -> make fails, no PASS" "1 0" "$([ "$rc" != 0 ] && echo 1 || echo "rc=$rc") $(nrec '"verdict": "PASS"')"
rm -f "$SE/GNUmakefile" "$SE/Makefile"
printf '.PHONY: gates\ngates:\n\t@true\n' > "$SE/Makefile"
fresh fn; erd "$SE" --attest >/dev/null 2>&1; rc=$?
check "a Makefile that does not call the runner leaves no line: --attest EXECUTES the gate and it FAILs" "1 1 0" "$rc $(nrec '"source": "executed"') $(nrec '"source": "attested"')"
rm -f "$SE/Makefile"
tmo() { if command -v timeout >/dev/null 2>&1; then timeout "$@"; else perl -e 'alarm shift; exec @ARGV' "$@"; fi; }
# the re-exec is bounded: a runner whose cleaning is sabotaged (the re-exec keeps the environment) must give up after ONE attempt
SH="$T/repoh"; cp -R "$SE" "$SH"
sed 's|exec /usr/bin/env -i ${CENV\[@\]+"${CENV\[@\]}"} "$_cs_b" --noprofile --norc -p|exec /usr/bin/env "$_cs_b" --noprofile --norc|' "$root/scripts/run-once.sh" > "$SH/scripts/run-once.sh"
check "sabotage control: the mutant run-once.sh really differs" differs "$(cmp -s "$SH/scripts/run-once.sh" "$root/scripts/run-once.sh" && echo same || echo differs)"
: > "$LOG"; (cd "$SH" && BASH_ENV="$T/ba.sh" tmo 20 bash scripts/evidence-record.sh --run g-real >"$T/ho" 2>&1); rc=$?
check "the re-exec is bounded: cleaning sabotaged -> exit 2 after ONE attempt, no loop (timeout 20), no gate ran" "2 0 1" "$rc $(execs) $(grep -c 'clean start did not give a clean shell' "$T/ho")"
[[ "$ONLY" == hostile ]] && finish

# ---- the fixture shared by the attest cases: two gates, recorded ONCE by `--run gates` (run id r1, clean tree) -------
S="$T/repo"; build "$S" '"g-one|bash gates/one.sh"' '"g-two|bash gates/two.sh"'
RES0="$T/res0.tsv"; fresh zero; RES="$RES0"; erd "$S" --run gates >/dev/null 2>&1
use0() { RES="$T/res-$1.tsv"; cp "$RES0" "$RES"; RUN=r1; : > "$LOG"; }
er() { erd "$S" "$@"; }

# ---- attested when everything matches (the lines are the ones --run wrote) --------------------------------------
use0 a; er --attest >"$T/o" 2>&1; rc=$?
check "attest: every gate matches -> exit 0" 0 "$rc"
check "attest: ...and nothing was executed again" 0 "$(execs)"
check "attest: the record marks both gates attested, none executed" "2 0" "$(nrec '"source": "attested"') $(nrec '"source": "executed"')"
check "attest: totals carry executed 0 / attested 2" 1 "$(nrec '"executed": 0, "attested": 2')"
check "attest: an attested gate names its results-file line" 1 "$(nrec '"results_line": 1,')"
check "attest: an attested gate carries the recorded output hash" 2 "$(grep -c '"output_sha256": "[0-9a-f]\{64\}"' <<<"$REC")"
check "attest: the evidence column of the record is the gate's own summary" 1 "$(nrec '"evidence": "ok-one summary"')"
check "attest: the verdict line counts attested vs executed" 1 "$(grep -c 'VERDICT: COMPLETE -- 2/2 gates passed (2 attested, 0 executed)' "$T/o")"
check "attest: the record is named after the commit (clean tree)" "$(git -C "$S" rev-parse --short HEAD).json" "$(basename "$S"/.prod/evidence/*.json)"

# ---- executed when it does not: ONE gate (S1, the runner untracked so an edit of it is invisible to git) ---------------
S1="$T/repo1"; build "$S1" '"g-one|bash gates/one.sh"'
printf 'scripts/run-once.sh\n' >> "$S1/.git/info/exclude"; git -C "$S1" rm -q --cached scripts/run-once.sh; git -C "$S1" -c user.email=t@t -c user.name=t commit -q -m untrack
RES1="$T/res1.tsv"; fresh one; RES="$RES1"; erd "$S1" --run gates >/dev/null 2>&1
e1() { erd "$S1" "$@"; }
fresh b; e1 --attest >"$T/o" 2>&1; rc=$?
check "no results file -> the gate executed, exit 0, the record says why" "0 1 1 1" "$rc $(nrec '"source": "executed"') $(execs) $(nrec '"why_executed": "no-results-file"')"
from b6 "$RES1"; echo more >> "$S1/tracked.txt"; e1 --attest >"$T/o" 2>&1
check "tree dirty (clean when run) -> executed; the record is named dirty-*, so it is no attestation" "1 0 1" "$(execs) $(nrec '"source": "attested"') $(find "$S1/.prod/evidence" -name 'dirty-*.json' | grep -c .)"
git -C "$S1" checkout -q -- tracked.txt
from b9 "$RES1"; (cd "$S1" && rm -f .prod/evidence/*.json && env -u EVIDENCE_RUN_ID EVIDENCE_RESULTS="$RES" bash scripts/evidence-record.sh --attest >"$T/o" 2>&1); rc=$?; rec_load "$S1"
check "no run id at attest time -> executed (a local run attests nothing), the record says why" "0 1 1 1" "$rc $(nrec '"source": "executed"') $(execs) $(nrec '"why_executed": "no-run-id"')"
from b12 "$RES1"; awk -F'\t' -v OFS='\t' '{ $8 = $8 - 7200; print }' "$RES" > "$RES.o" && mv "$RES.o" "$RES"
ctl=$(cd "$S1" && EVIDENCE_MAX_AGE=99999 EVIDENCE_RESULTS="$RES" EVIDENCE_RUN_ID=r1 bash scripts/run-once.sh resolve g-one 'bash gates/one.sh' | cut -f1)
(cd "$S1" && rm -f .prod/evidence/*.json && env EVIDENCE_MAX_AGE=99999 EVIDENCE_RESULTS="$RES" EVIDENCE_RUN_ID=r1 bash scripts/evidence-record.sh --attest >/dev/null 2>&1); rec_load "$S1"
check "clean self: a caller's EVIDENCE_MAX_AGE cannot stretch the age limit (2-hour-old line: control attests, the recorder executes)" "attested 1 0" "$ctl $(execs) $(nrec '"source": "attested"')"
from b13 "$RES1"; e1 --attest >/dev/null 2>&1; base=$(execs)
check "runner hash: untouched runner -> the line of --run is attested, nothing re-run (control)" "1 0" "$(nrec '"source": "attested"') $base"
echo '# edited after the run' >> "$S1/scripts/run-once.sh"
e1 --attest >/dev/null 2>&1
check "runner hash: the runner edited between --run and --attest (git cannot see it) -> executed" "1 0" "$(execs) $(nrec '"source": "attested"')"
# failures: a recorded failure fails the record and is NOT re-executed
use0 c; colset "$RES" g-one 4 1; er --attest >"$T/o" 2>&1; rc=$?
check "a recorded failure fails the record (exit 1), is NOT re-executed, one FAIL and one PASS" "1 0 1 1" "$rc $(execs) $(nrec '"verdict": "FAIL"') $(nrec '"verdict": "PASS"')"
check "...and the verdict line says INCOMPLETE" 1 "$(grep -c 'VERDICT: INCOMPLETE -- 1 gate(s) failed' "$T/o")"
# the match rules on ONE gate each, in ONE run: a four-gate repo, one attested control, three defects
SB="$T/repob"; build "$SB" '"g-one|bash gates/one.sh"' '"g-two|bash gates/two.sh"' '"g-three|bash gates/one.sh three"' '"g-bad|bash gates/bad.sh"'
fresh mix; erd "$SB" --run g-one g-two >/dev/null 2>&1
colset "$RES" g-two 3 'bash gates/two.sh --different'
awk -F'\t' -v OFS='\t' '{ print } $2 == "g-one" { $2 = "g-three"; $3 = "bash gates/one.sh three"; $4 = 1; print; $4 = 0; print }' "$RES" > "$RES.m" && mv "$RES.m" "$RES"
: > "$LOG"; erd "$SB" --attest >"$T/o" 2>&1; rc=$?
check "attest mix: one attested (control), argv differs / conflicting lines / no line -> executed, a failing one fails the record" "1 3 3 1" "$(nrec '"source": "attested"') $(nrec '"source": "executed"') $(execs) $rc"
check "attest mix: ...the reasons are named (argv differs, conflict, no line)" "2 1" "$(nrec '"why_executed": "no-line-for-this-id-command-tree-run"') $(nrec '"why_executed": "conflicting-lines-for-this-id"')"
check "attest mix: ...the executed failing gate is FAIL in the record" 1 "$(grep -c '"gate": "g-bad".*"verdict": "FAIL"' <<<"$REC")"

# ---- --run: the set, the order, stop at the first failure, and --list --------------------------------------------
SR="$T/repor"
R_PRE_IDS='g-pre' R_POST_IDS='g-post' R_AGG_IDS='g-agg' build "$SR" '"g-pre|bash gates/one.sh pre"' '"g-a|bash gates/one.sh a"' '"g-b|bash gates/two.sh b"' '"g-post|bash gates/two.sh post"' '"g-agg|bash gates/two.sh agg"'
printf '#!/usr/bin/env bash\necho "$1" >> "%s"\nrc=0; [ -f gates/stop.rc ] && read -r rc < gates/stop.rc\nexit "$rc"\n' "$LOG" > "$SR/gates/one.sh"; cp "$SR/gates/one.sh" "$SR/gates/two.sh"
git -C "$SR" add -A; git -C "$SR" -c user.email=t@t -c user.name=t commit -q -m ids
runr() { (cd "$SR" && bash scripts/evidence-record.sh --run "$@"); }
ids_run() { local o="" w; for w in $(order); do o+="${o:+ }g-$w"; done; echo "$o"; }
listr() { (cd "$SR" && bash scripts/evidence-record.sh --list "$1" | tr '\n' ' ' | sed 's/ $//'); }
fresh r1; (cd "$SR" && EVIDENCE_RUN_ID=r1 EVIDENCE_RESULTS="$RES" bash scripts/evidence-record.sh --run gates >"$T/o" 2>&1); rc=$?
check "--run gates: exactly the main gates, in GATES order, a PASS line each" "0 a b 2" "$rc $(order) $(grep -c '^  PASS  ' "$T/o")"
check "--run gates with a run id writes exactly one line per gate it ran, ids, argv and exit codes as executed" "2 g-a g-b 0 0" "$(wc -l <"$RES" | tr -d ' ') $(cut -f2 "$RES" | tr '\n' ' ' | sed 's/ $//') $(cut -f4 "$RES" | tr '\n' ' ' | sed 's/ $//')"
check "--list main equals what --run gates executed, in the same order" "$(ids_run)" "$(listr main)"
check "--list: pre, post, agg and all are the recorder's own resolution" "g-pre|g-post|g-agg|g-pre g-a g-b g-post g-agg" "$(listr pre)|$(listr post)|$(listr agg)|$(listr all)"
cp "$SR/scripts/evidence-record.sh" "$T/er.sr"
sed 's/^AGG_IDS=(\(.*\))$/AGG_IDS=(\1)\nPOST_IDS+=(g-a)/' "$T/er.sr" > "$SR/scripts/evidence-record.sh"
fresh r1m; runr gates >/dev/null 2>&1
check "--list follows a \`+=\` move out of main, and --run gates agrees (both skip it)" "g-b|b" "$(listr main)|$(order)"
cp "$T/er.sr" "$SR/scripts/evidence-record.sh"
(cd "$SR" && bash scripts/evidence-record.sh --list nope >/dev/null 2>&1); check "--list with an unknown group is refused (2)" 2 "$?"
fresh r2; runr check-fast >/dev/null 2>&1; check "--run check-fast: the pre gates, then the main ones" "pre a b" "$(order)"
fresh r3; runr g-post g-a >/dev/null 2>&1; check "--run <id> <id> (no run id): those gates in the order given, post and ordinary alike, and no results file" "post a absent" "$(order) $(present "$RES")"
fresh r4; runr g-a nope >"$T/o" 2>&1; rc=$?
check "--run with an unknown id: exit 2 and NOTHING ran (validated before executing)" "2 0 1" "$rc $(execs) $(grep -c "unknown gate id or target 'nope'" "$T/o")"
fresh r5; (cd "$SR" && bash scripts/evidence-record.sh --run >/dev/null 2>&1); check "--run with nothing to run: exit 2" 2 "$?"
fresh r6; echo 3 > "$SR/gates/stop.rc"; (cd "$SR" && EVIDENCE_RUN_ID=r1 EVIDENCE_RESULTS="$RES" bash scripts/evidence-record.sh --run gates >"$T/o" 2>&1); rc=$?; rm -f "$SR/gates/stop.rc"
check "--run gates stops at the FIRST failure: exit 3 (the gate's own), the second gate did not run, recorded as exit 3, never a pass" "3 a 1 3" "$rc $(order) $(grep -c '^  FAIL  g-a' "$T/o") $(cut -f4 "$RES")"
(cd "$SR" && bash scripts/evidence-record.sh --run gates --attest >/dev/null 2>&1) ; check "--run and --attest together are refused (2)" 2 "$?"
(cd "$S" && bash scripts/evidence-record.sh --bogus >"$T/o" 2>&1); check "an unknown argument is refused (2)" 2 "$?"

# ---- the dry run: nothing runs, nothing is written ------------------------------------------------------------
fresh dry
(cd "$S" && MAKEFLAGS=n EVIDENCE_RUN_ID=r1 EVIDENCE_RESULTS="$RES" bash scripts/evidence-record.sh --run gates >"$T/o" 2>&1); rc=$?
check "dry run: MAKEFLAGS=n -> --run refused (2), nothing executed, no line written" "2 0 absent" "$rc $(execs) $(present "$RES")"
rm -f "$S"/.prod/evidence/*.json
(cd "$S" && MAKEFLAGS=n EVIDENCE_RUN_ID=r1 EVIDENCE_RESULTS="$RES" bash scripts/evidence-record.sh --attest >"$T/o" 2>&1); rc=$?
check "dry run: --attest refused too (2): no record file, no execution" "2 0 0" "$rc $(execs) $(ls "$S"/.prod/evidence/*.json 2>/dev/null | wc -l | tr -d ' ')"
(cd "$S" && env -i PATH="$PATH" MAKEFLAGS=n bash scripts/evidence-record.sh --run gates >/dev/null 2>&1); check "dry run: refused (2) also when the shell is otherwise clean already (no re-exec to hide behind)" 2 "$?"
(cd "$S" && MAKEFLAGS=-Otarget EVIDENCE_RUN_ID=r1 EVIDENCE_RESULTS="$RES" bash scripts/evidence-record.sh --run g-one >/dev/null 2>&1); check "dry run: MAKEFLAGS=-Otarget is NOT a dry run (no false refusal): runs" "0 1" "$? $(execs)"

# ---- a recorded `true` for a real failing gate (reviewer forgery B2): the repo of the accident-class cases -------------
fresh f; rod "$SE" --as 'bash gates/real.sh' g-real -- true >/dev/null 2>&1; rc=$?
check "forgery: \`--as '<label>' g-real -- true\` is refused by the runner (2), no line" "2 absent" "$rc $(present "$RES")"
rod "$SE" g-real -- true >/dev/null 2>&1
erd "$SE" --attest >"$T/o" 2>&1; rc=$?
check "forgery: a recorded \`true\` for g-real is NOT attested: executed, the real gate FAILs, the record says FAIL" "1 1 0 1 1" "$rc $(nrec '"source": "executed"') $(nrec '"source": "attested"') $(execs) $(grep -c '"gate": "g-real".*"verdict": "FAIL"' <<<"$REC")"

# ---- canonical argv: spaces / quotes / dollar / semicolon, a glob, a bash -c loop ---------------------------------
S4="$T/repo4"
build "$S4" '"g-one|bash gates/one.sh"' \
  '"g-loop|bash -c '\''for d in gates; do [ -d \"\$d\" ] || continue; done; echo loop-ok'\''"' \
  '"g-glob|bash gates/glob.sh gates/*.sh"' \
  $'"g-args|bash gates/arg.sh \'a b\' \'\\$HOME\' \'x;y\'"'
printf '#!/usr/bin/env bash\necho x >> "%s"\necho "glob-args $#"\n' "$LOG" > "$S4/gates/glob.sh"
printf '#!/usr/bin/env bash\necho x >> "%s"\necho "args $#"\n' "$LOG" > "$S4/gates/arg.sh"
git -C "$S4" add -A; git -C "$S4" -c user.email=t@t -c user.name=t commit -q -m gates
GLOBARGV="bash gates/glob.sh gates/arg.sh gates/bad.sh gates/glob.sh gates/one.sh gates/two.sh"
fresh d; erd "$S4" --run gates >/dev/null 2>&1; rc=$?; cp "$RES" "$T/res-d0.tsv"; base=$(execs)
erd "$S4" --attest >"$T/o4" 2>&1; rc2=$?
check "canonical: the loop, the glob and the quoted args written by --run are ATTESTED by --attest, none re-run" "0 0 4 0 0" "$rc $rc2 $(nrec '"source": "attested"') $(nrec '"source": "executed"') $(( $(execs) - base ))"
check "canonical: the command column of the glob gate is the EXPANDED argv" "$GLOBARGV" "$(awk -F'\t' '$2=="g-glob"{print $3}' "$T/res-d0.tsv")"
fresh d3; env GLOBIGNORE='*' BASHOPTS=nullglob SHELLOPTS=noglob bash -c 'cd "$1" && EVIDENCE_RUN_ID=r1 EVIDENCE_RESULTS="$2" bash scripts/evidence-record.sh --run g-glob' x "$S4" "$RES" >/dev/null 2>&1
check "clean self: GLOBIGNORE / BASHOPTS / SHELLOPTS from the caller do not change how a GATES glob expands" "$GLOBARGV" "$(awk -F'\t' '$2=="g-glob"{print $3}' "$RES")"
from d2 "$T/res-d0.tsv"
want=$(printf 'g-one\t%s\ng-loop\t%s\ng-glob\t%s\ng-args\t%s\n' "$(rod "$S4" canon bash gates/one.sh)" "$(rod "$S4" canon bash -c 'for d in gates; do [ -d "$d" ] || continue; done; echo DIFFERENT')" "$(rod "$S4" canon bash gates/glob.sh gates/one.sh)" "$(rod "$S4" canon bash gates/arg.sh a b '$HOME' 'x;y')")
check "canonical: another loop body, another glob expansion, args split differently -> miss; the untouched argv -> attested" "attested miss miss miss" "$(printf '%s' "$want" | rod "$S4" resolve-set | cut -f2 | tr '\n' ' ' | sed 's/ $//')"

# ---- probe-selftests: derived from per-suite lines of THIS run, and the ONE suite list --------------------------------
S5="$T/repo5"
R_PRE_IDS='' R_AGG_IDS='probe-selftests' build "$S5" '"g-one|bash gates/one.sh"' '"probe-selftests|bash gates/agg.sh"'
printf '#!/usr/bin/env bash\necho x >> "%s"\necho agg-ran\nexit 1\n' "$LOG" > "$S5/gates/agg.sh"
mkdir -p "$S5/_shared/probes/tests" "$S5/scripts/tests" "$S5/tpl"
for sf in _shared/probes/a-selftest.sh _shared/probes/tests/b-selftest.sh scripts/tests/c-selftest.sh tpl/t-selftest.sh; do
  printf '#!/usr/bin/env bash\necho x >> "%s"\necho "3 ok, 0 failed"\nrc=0; [ -f %s.rc ] && read -r rc < %s.rc\nexit "$rc"\n' "$LOG" "${sf%.sh}" "${sf%.sh}" > "$S5/$sf"
done
printf 'scripts/tests/*.rc\n_shared/probes/*.rc\ntpl/*.rc\n' >> "$S5/.git/info/exclude"
mk5() { # $1 = SUITE_GLOBS body, $2 = SUITE_REQUIRED body, $3 = SUITE_TEMPLATE body
  R_SUITE_GLOBS="$1" R_SUITE_REQUIRED="$2" R_SUITE_TEMPLATE="$3" R_PRE_IDS='' R_AGG_IDS='probe-selftests' R_GATES=$(printf '  %s\n' '"g-one|bash gates/one.sh"' '"probe-selftests|bash gates/agg.sh"') mkrec "$S5/scripts/evidence-record.sh"; }
G3="  '_shared/probes/*-selftest.sh'
  '_shared/probes/tests/*-selftest.sh'
  'scripts/tests/*-selftest.sh'"
mk5 "$G3" "  _shared/probes/a-selftest.sh" "  tpl/t-selftest.sh"
git -C "$S5" add -A; git -C "$S5" -c user.email=t@t -c user.name=t commit -q -m base5
fresh s0b; echo 1 > "$S5/scripts/tests/c-selftest.rc"; (cd "$S5" && bash scripts/evidence-record.sh --run selftests >"$T/o5" 2>&1); rc=$?; rm -f "$S5/scripts/tests/c-selftest.rc"
check "selftests: a failing suite stops the run (exit 1), prints its output tail, later suites do not run" "1 3 1" "$rc $(execs) $(grep -c '3 ok, 0 failed' "$T/o5")"
fresh s1; erd "$S5" --run selftests g-one >"$T/o5" 2>&1; rc=$?; cp "$RES" "$T/res-s1m.tsv"; base=$(execs)
check "selftests: --run selftests runs exactly the resolved suites (then g-one), globs first then the template ones, in order, and states the total" "0 5 4 1" "$rc $base $(grep -c ' ok$' "$T/o5") $(grep -c '^selftests: 4 passed' "$T/o5")"
erd "$S5" --attest >"$T/o5" 2>&1; rc=$?
check "selftests: every suite has its own line -> probe-selftests ATTESTED, nothing re-executed" "0 2 0 0" "$rc $(nrec '"source": "attested"') $(nrec '"source": "executed"') $(( $(execs) - base ))"
check "selftests: ...derived from the four suite lines, named in the record" 1 "$(nrec '"derived_from_suites": 4')"
# an aggregate line (forged as a PASS) never vouches, and a suite line under another argv does not count
from s2 "$T/res-s1m.tsv"; rod "$S5" probe-selftests -- bash gates/agg.sh >/dev/null 2>&1; colset "$RES" probe-selftests 4 0; : > "$LOG"
colset "$RES" selftest:scripts/tests/c-selftest.sh 3 "bash -c echo\\ 3\\ ok"
erd "$S5" --attest >"$T/o5" 2>&1
check "forgery: a PASS aggregate line alone never vouches, a suite line under another argv does not count -> probe-selftests executed" "1 1 1" "$(nrec '"source": "executed"') $(nrec '"source": "attested"') $(execs)"
check "forgery: ...and the record names the suite" 1 "$(nrec '"why_executed": "suite scripts/tests/c-selftest.sh: no-line-for-this-id-command-tree-run"')"
from s3 "$T/res-s1m.tsv"; colset "$RES" selftest:scripts/tests/c-selftest.sh 4 1
erd "$S5" --attest >"$T/o5" 2>&1; rc=$?
check "selftests: a recorded FAILING suite -> probe-selftests attested FAIL (exit 1), not re-run" "1 0" "$rc $(execs)"
check "selftests: ...the evidence names the suite and its exit code" 1 "$(nrec '"evidence": "failing suite(s): scripts/tests/c-selftest.sh (exit 1)"')"
# the suite list's own guards (exit 2 naming the problem, nothing run), for --run selftests AND for attest
mk5 "$G3" "  _shared/probes/a-selftest.sh  _shared/probes/zz-selftest.sh" "  tpl/t-selftest.sh"
fresh s7; (cd "$S5" && bash scripts/evidence-record.sh --run selftests >"$T/o5" 2>&1); rc=$?
check "selftests: a REQUIRED suite that does not exist -> exit 2 naming it, nothing run" "2 1 0" "$rc $(grep -c 'zz-selftest.sh is missing' "$T/o5") $(execs)"
mk5 "$G3" "  _shared/probes/a-selftest.sh" "  tpl/gone-selftest.sh"
fresh s8; (cd "$S5" && bash scripts/evidence-record.sh --run selftests >"$T/o5" 2>&1); rc=$?
check "selftests: a missing template suite -> exit 2 naming it" "2 1" "$rc $(grep -c 'gone-selftest.sh is missing' "$T/o5")"
printf '#!/usr/bin/env bash\necho "1 ok"\n' > "$S5/odd-selftest.sh"
mk5 "$G3" "  _shared/probes/a-selftest.sh  odd-selftest.sh" "  tpl/t-selftest.sh"
fresh s9; (cd "$S5" && bash scripts/evidence-record.sh --run selftests >"$T/o5" 2>&1); rc=$?
check "selftests: a REQUIRED suite outside every glob -> exit 2 'did not run it'" "2 1" "$rc $(grep -c 'odd-selftest.sh exists but the glob did not run it' "$T/o5")"
mk5 "  'nowhere/*-selftest.sh'" "" ""
fresh s10; (cd "$S5" && bash scripts/evidence-record.sh --run selftests >"$T/o5" 2>&1); rc=$?
check "selftests: globs that resolve to ZERO suites -> exit 2, never a pass over an empty set" "2 1" "$rc $(grep -c 'found ZERO selftests' "$T/o5")"
fresh s11; rm -f "$S5/odd-selftest.sh"; rod "$S5" g-one -- bash gates/one.sh >/dev/null 2>&1; erd "$S5" --attest >"$T/o5" 2>&1
check "selftests: attest over a broken suite list does NOT derive probe-selftests from lines (executed)" "1 1" "$(nrec '"source": "executed"') $(nrec '"why_executed": "suite-list: ')"

# ---- the real file: the shape the rest of the repo pins, asked of the recorder itself ---------------------------
real_ids=$(sed -n '/^GATES=(/,/^)/p' "$root/scripts/evidence-record.sh" | grep -vE '^[[:space:]]*#' | sed -nE 's/^[[:space:]]*"([A-Za-z0-9_-]+)\|.*"[[:space:]]*$/\1/p')
check "real GATES: every entry is two-field id|command and ids are unique" "$(printf '%s\n' "$real_ids" | grep -c .)" "$(printf '%s\n' "$real_ids" | sort -u | grep -c .)"
all_ids=$(bash "$root/scripts/evidence-record.sh" --list all); main_ids=$(bash "$root/scripts/evidence-record.sh" --list main)
grp=$(grep -E '^(PRE_IDS|POST_IDS|AGG_IDS)=\(' "$root/scripts/evidence-record.sh" | sed -E 's/^[A-Z_]+=\((.*)\)/\1/' | tr ' ' '\n' | grep .)
check "real GATES: --list all names exactly the gates of the GATES array" "$real_ids" "$all_ids"
check "real GATES: every PRE/POST/AGG id names a real gate (a typo would silently move a gate to main)" "" "$(for g in $grp; do [[ $'\n'"$all_ids"$'\n' == *$'\n'"$g"$'\n'* ]] || printf '%s ' "$g"; done)"
check "real GATES: --list main (what make gates runs) is the 18 gates make gates ran before, and main + pre/post/agg is every gate" "18 $(printf '%s\n' "$all_ids" | grep -c .)" "$(printf '%s\n' "$main_ids" | grep -c .) $(( $(printf '%s\n' "$main_ids" | grep -c .) + $(printf '%s\n' "$grp" | grep -c .) ))"

finish
