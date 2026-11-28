#!/usr/bin/env bash
# evidence-record-selftest.sh -- scripts/evidence-record.sh RUNS the gates (`--run`, one at a time,
# through run-once.sh, in a clean environment) and, in `--attest`, takes a gate from the run-once
# results file ONLY for a same-id, same-command (canonical argv), same-tree, same-run, same-contract
# well-formed line, otherwise executes it, and says which in the record; a recorded failure fails the
# record; `probe-selftests` is attested only from per-suite lines of the same run; nothing reads the
# Makefile, so no Makefile edit can forge an attested PASS (the round-2 forgeries are cases below).
# provenance: candidate; ttl: 2027-02-27; pinning: true
# Hermetic: fake gates are tiny scripts in a scratch git repo; the GATES / suite arrays are replaced
# in a scratch COPY of the script, everything else in it is the real code.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
unset EVIDENCE_RESULTS EVIDENCE_RUN_ID EVIDENCE_MAX_AGE MAKEFLAGS MFLAGS EVIDENCE_CLEAN_ENV
T=$(mktemp -d) || exit 2
trap 'rm -rf "$T"' EXIT
LOG="$T/exec.log"

CASES=0; FAILED=0
check() { CASES=$((CASES+1)); if [ "$2" = "$3" ]; then printf '  ok   %-72s %s\n' "$1" "$3"
  else printf '  FAIL %-72s expected=%s actual=%s\n' "$1" "$2" "$3"; FAILED=$((FAILED+1)); fi; }

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
    printf '#!/usr/bin/env bash\necho "%s" >> "%s"\necho "ok-%s summary"\nexit "$(cat gates/%s.rc 2>/dev/null || echo 0)"\n' "$g" "$LOG" "$g" "$g" > "$d/gates/$g.sh"
  done
  printf '#!/usr/bin/env bash\necho bad >> "%s"\necho "bad summary"\nexit 1\n' "$LOG" > "$d/gates/bad.sh"
  echo "tracked" > "$d/tracked.txt"
  git -C "$d" init -q . && printf 'gates/*.rc\nscripts/*-ignored\n' >> "$d/.git/info/exclude" && git -C "$d" add -A && git -C "$d" -c user.email=t@t -c user.name=t commit -q -m base
}
GATES2=('"g-one|bash gates/one.sh"' '"g-two|bash gates/two.sh"')
S="$T/repo"; build "$S" "${GATES2[@]}"

ro()  { (cd "$S" && EVIDENCE_RESULTS="$RES" EVIDENCE_RUN_ID="${RUN:-r1}" bash scripts/run-once.sh "$@"); }
er()  { (cd "$S" && rm -f .prod/evidence/*.json && EVIDENCE_RESULTS="$RES" EVIDENCE_RUN_ID="${RUN:-r1}" bash scripts/evidence-record.sh "$@"); }
rod() { local d="$1"; shift; (cd "$d" && EVIDENCE_RESULTS="$RES" EVIDENCE_RUN_ID="${RUN:-r1}" bash scripts/run-once.sh "$@"); }
erd() { local d="$1"; shift; (cd "$d" && rm -f .prod/evidence/*.json && EVIDENCE_RESULTS="$RES" EVIDENCE_RUN_ID="${RUN:-r1}" bash scripts/evidence-record.sh "$@"); }
nrec() { grep -c "$1" "$S"/.prod/evidence/*.json | awk -F: '{s+=$NF} END{print s+0}'; }
nrecd() { local d="$1"; shift; grep -c "$1" "$d"/.prod/evidence/*.json | awk -F: '{s+=$NF} END{print s+0}'; }
execs() { local n; n=$(grep -c . "$LOG" 2>/dev/null); echo "${n:-0}"; }
order() { tr '\n' ' ' <"$LOG" 2>/dev/null | sed 's/ $//'; }
fresh() { RES="$T/res-$1.tsv"; RUN=r1; rm -f "$RES" "$LOG"; : > "$LOG"; }
record_both() { ro g-one -- bash gates/one.sh >/dev/null 2>&1; ro g-two -- bash gates/two.sh >/dev/null 2>&1; }
present() { [ -e "$1" ] && echo present || echo absent; }

# ---- attested when everything matches -------------------------------------------------------
fresh a; record_both; base=$(execs)
er --attest >"$T/o" 2>&1; rc=$?
check "attest: every gate matches -> exit 0" 0 "$rc"
check "attest: ...and nothing was executed again" "$base" "$(execs)"
check "attest: the record marks both gates attested" 2 "$(nrec '"source": "attested"')"
check "attest: ...and none executed" 0 "$(nrec '"source": "executed"')"
check "attest: totals carry executed 0 / attested 2" 1 "$(nrec '"executed": 0, "attested": 2')"
check "attest: an attested gate names its results-file line" 1 "$(nrec '"results_line": 1,')"
check "attest: an attested gate carries the recorded output hash" 2 "$(nrec '"output_sha256": "[0-9a-f]\{64\}"')"
check "attest: the evidence column of the record is the gate's own summary" 1 "$(nrec '"evidence": "ok-one summary"')"
check "attest: the verdict line counts attested vs executed" 1 "$(grep -c 'VERDICT: COMPLETE -- 2/2 gates passed (2 attested, 0 executed)' "$T/o")"
check "attest: the record is named after the commit (clean tree)" "$(git -C "$S" rev-parse --short HEAD).json" "$(basename "$S"/.prod/evidence/*.json)"
fresh a2; er --run gates >/dev/null 2>&1; base=$(execs); er --attest >"$T/o" 2>&1
check "run then attest: the lines --run wrote are exactly what --attest trusts (2 attested, 0 re-run)" "2 0" "$(nrec '"source": "attested"') $(( $(execs) - base ))"

# ---- executed when it does not ---------------------------------------------------------------
fresh b
er --attest >"$T/o" 2>&1; rc=$?
check "no results file -> both executed, exit 0" "0 2 2" "$rc $(nrec '"source": "executed"') $(execs)"
check "no results file -> the record says why" 2 "$(nrec '"why_executed": "no-results-file"')"
fresh b3; record_both; printf 'garbage\n' >> "$RES"; base=$(execs); er --attest >/dev/null 2>&1
check "malformed line in the file -> BOTH gates executed, none attested" "2 0" "$(( $(execs) - base )) $(nrec '"source": "attested"')"
fresh b4; record_both; base=$(execs); git -C "$S" -c user.email=t@t -c user.name=t commit -q --allow-empty -m other-head
er --attest >/dev/null 2>&1
check "another HEAD (another tree) -> both executed" "2 0" "$(( $(execs) - base )) $(nrec '"source": "attested"')"
fresh b5; ro g-one -- bash gates/one.sh >/dev/null 2>&1; ro g-two -- bash gates/two.sh --different >/dev/null 2>&1; base=$(execs)
er --attest >/dev/null 2>&1
check "argv differs for ONE gate (an extra argument) -> only that gate executed" "1 1 1" "$(( $(execs) - base )) $(nrec '"source": "executed"') $(nrec '"source": "attested"')"
fresh b6; record_both; echo more >> "$S/tracked.txt"; base=$(execs); er --attest >"$T/o" 2>&1
check "tree dirty-state differs (clean when run, dirty now) -> both executed" "2 0" "$(( $(execs) - base )) $(nrec '"source": "attested"')"
check "a dirty tree names the record so it cannot be mistaken for an attestation" 1 "$(find "$S/.prod/evidence" -name 'dirty-*.json' | grep -c .)"
git -C "$S" checkout -q -- tracked.txt
fresh b7; record_both; RUN=r2; base=$(execs); er --attest >/dev/null 2>&1; RUN=r1
check "another run id -> both executed" "2 0" "$(( $(execs) - base )) $(nrec '"source": "attested"')"
fresh b9; record_both; base=$(execs)
(cd "$S" && rm -f .prod/evidence/*.json && env -u EVIDENCE_RUN_ID EVIDENCE_RESULTS="$RES" bash scripts/evidence-record.sh --attest >"$T/o" 2>&1); rc=$?
check "no run id at attest time -> both executed (a local run attests nothing)" "0 2 2" "$rc $(nrec '"source": "executed"') $(( $(execs) - base ))"
check "...and the record says why" 2 "$(nrec '"why_executed": "no-run-id"')"
fresh b10
(cd "$S" && env -u EVIDENCE_RUN_ID EVIDENCE_RESULTS="$RES" bash scripts/evidence-record.sh --run gates >/dev/null 2>&1)
check "--run WITHOUT a run id: the gates run (2 executions) and no results file is written" "2 absent" "$(execs) $(present "$RES")"
(cd "$S" && rm -f .prod/evidence/*.json && EVIDENCE_RUN_ID=r1 EVIDENCE_RESULTS="$RES" bash scripts/evidence-record.sh --attest >/dev/null 2>&1)
check "a gate run WITHOUT a run id left no line, so a later attest finds nothing to trust" "0 2" "$(nrec '"source": "attested"') $(nrec '"source": "executed"')"
fresh b12; record_both; awk -F'\t' -v OFS='\t' '{ $8 = $8 - 7200; print }' "$RES" > "$RES.old" && mv "$RES.old" "$RES"
ctl=$(cd "$S" && EVIDENCE_MAX_AGE=99999 EVIDENCE_RESULTS="$RES" EVIDENCE_RUN_ID=r1 bash scripts/run-once.sh resolve g-one 'bash gates/one.sh' | cut -f1)
base=$(execs); (cd "$S" && rm -f .prod/evidence/*.json && env EVIDENCE_MAX_AGE=99999 EVIDENCE_RESULTS="$RES" EVIDENCE_RUN_ID=r1 bash scripts/evidence-record.sh --attest >/dev/null 2>&1)
check "clean self: a caller's EVIDENCE_MAX_AGE cannot stretch the age limit (2-hour-old lines: control attests, the recorder executes both)" "attested 2 0" "$ctl $(( $(execs) - base )) $(nrec '"source": "attested"')"
fresh b11; record_both; : > "$LOG"; (cd "$S" && echo '# touched' >> scripts/run-once.sh); er --attest >/dev/null 2>&1
check "the RUNNER edited since the lines were written (tracked, so also another tree) -> both executed" "2 0" "$(execs) $(nrec '"source": "attested"')"
git -C "$S" checkout -q -- scripts/run-once.sh

# ---- failures --------------------------------------------------------------------------------
fresh c; echo 1 > "$S/gates/one.rc"; ro g-one -- bash gates/one.sh >/dev/null 2>&1; rm -f "$S/gates/one.rc"; ro g-two -- bash gates/two.sh >/dev/null 2>&1; base=$(execs)
er --attest >"$T/o" 2>&1; rc=$?
check "a recorded failure fails the record (exit 1)" 1 "$rc"
check "...it is NOT re-executed to see whether it passes now" "$base" "$(execs)"
check "...the record has one FAIL and one PASS" "1 1" "$(nrec '"verdict": "FAIL"') $(nrec '"verdict": "PASS"')"
check "...and the verdict line says INCOMPLETE" 1 "$(grep -c 'VERDICT: INCOMPLETE -- 1 gate(s) failed' "$T/o")"
fresh c2; record_both
echo 1 > "$S/gates/one.rc"; ro g-one -- bash gates/one.sh >/dev/null 2>&1; rm -f "$S/gates/one.rc"; base=$(execs)
er --attest >"$T/o" 2>&1; rc=$?
check "conflicting lines for one id -> that gate executed (and passes)" "0 1 1" "$rc $(nrec '"source": "executed"') $(( $(execs) - base ))"
check "...the record names the conflict" 1 "$(nrec '"why_executed": "conflicting-lines-for-this-id"')"
S2="$T/repo2"; build "$S2" '"g-one|bash gates/one.sh"' '"g-bad|bash gates/bad.sh"'
fresh c4; (cd "$S2" && bash scripts/evidence-record.sh --attest >"$T/o2" 2>&1); rc=$?
check "an EXECUTED failing gate fails the record too (exit 1)" 1 "$rc"
check "...with the failure named FAIL in the record" 1 "$(grep -c '"gate": "g-bad".*"verdict": "FAIL"' "$S2"/.prod/evidence/*.json)"

# ---- --run: the set, the order, stop at the first failure -----------------------------------------
SR="$T/repor"
R_PRE_IDS='g-pre' R_POST_IDS='g-post' R_AGG_IDS='g-agg' build "$SR" '"g-pre|bash gates/one.sh pre"' '"g-a|bash gates/one.sh a"' '"g-b|bash gates/two.sh b"' '"g-post|bash gates/two.sh post"' '"g-agg|bash gates/two.sh agg"'
printf '#!/usr/bin/env bash\necho "$1" >> "%s"\nexit "$(cat gates/stop.rc 2>/dev/null || echo 0)"\n' "$LOG" > "$SR/gates/one.sh"; cp "$SR/gates/one.sh" "$SR/gates/two.sh"
git -C "$SR" add -A; git -C "$SR" -c user.email=t@t -c user.name=t commit -q -m ids
runr() { (cd "$SR" && bash scripts/evidence-record.sh --run "$@"); }
fresh r1; runr gates >"$T/o" 2>&1; rc=$?
check "--run gates: exactly the main gates, in GATES order (pre, post and agg are not run)" "0 a b" "$rc $(order)"
check "--run gates: prints a PASS line per gate" "2" "$(grep -c '^  PASS  ' "$T/o")"
fresh r2; runr check-fast >/dev/null 2>&1; check "--run check-fast: the pre gates, then the main ones" "pre a b" "$(order)"
fresh r3; runr g-post g-a >/dev/null 2>&1; check "--run <id> <id>: those gates, in the order given (post and ordinary alike)" "post a" "$(order)"
fresh r4; runr g-a nope >"$T/o" 2>&1; rc=$?
check "--run with an unknown id: exit 2 and NOTHING ran (validated before executing)" "2 0 1" "$rc $(execs) $(grep -c "unknown gate id or target 'nope'" "$T/o")"
fresh r5; (cd "$SR" && bash scripts/evidence-record.sh --run >/dev/null 2>&1); check "--run with nothing to run: exit 2" 2 "$?"
fresh r6; echo 1 > "$SR/gates/stop.rc"; runr gates >"$T/o" 2>&1; rc=$?; rm -f "$SR/gates/stop.rc"
check "--run gates stops at the FIRST failure (as make did): exit 1, the second gate did not run" "1 a 1" "$rc $(order) $(grep -c '^  FAIL  g-a' "$T/o")"
fresh r7; (cd "$SR" && EVIDENCE_RUN_ID=r1 EVIDENCE_RESULTS="$RES" bash scripts/evidence-record.sh --run gates >/dev/null 2>&1)
check "--run gates with a run id writes exactly one line per gate it ran, ids and argv as executed" "2 g-a g-b" "$(wc -l <"$RES" | tr -d ' ') $(cut -f2 "$RES" | tr '\n' ' ' | sed 's/ $//')"
check "--run: the recorded exit code comes from the execution (both 0)" "0 0" "$(cut -f4 "$RES" | tr '\n' ' ' | sed 's/ $//')"
fresh r8; echo 3 > "$SR/gates/stop.rc"; (cd "$SR" && EVIDENCE_RUN_ID=r1 EVIDENCE_RESULTS="$RES" bash scripts/evidence-record.sh --run g-a >/dev/null 2>&1); rc=$?; rm -f "$SR/gates/stop.rc"
check "--run: a gate that FAILS is recorded with its real exit code (3), never as a pass" "3" "$(cut -f4 "$RES")"
fresh r9; (cd "$SR" && bash scripts/evidence-record.sh --run gates --attest >/dev/null 2>&1) ; check "--run and --attest together are refused (2)" 2 "$?"
(cd "$S" && bash scripts/evidence-record.sh --bogus >"$T/o" 2>&1); check "an unknown argument is refused (2)" 2 "$?"

# ---- the dry run: nothing runs, nothing is written ------------------------------------------------
fresh dry
(cd "$S" && MAKEFLAGS=n EVIDENCE_RUN_ID=r1 EVIDENCE_RESULTS="$RES" bash scripts/evidence-record.sh --run gates >"$T/o" 2>&1); rc=$?
check "dry run: MAKEFLAGS=n -> --run refused (2), nothing executed, no line written" "2 0 absent" "$rc $(execs) $(present "$RES")"
rm -f "$S"/.prod/evidence/*.json
(cd "$S" && MAKEFLAGS=n EVIDENCE_RUN_ID=r1 EVIDENCE_RESULTS="$RES" bash scripts/evidence-record.sh --attest >"$T/o" 2>&1); rc=$?
check "dry run: --attest refused too (2): no record file, no execution" "2 0 0" "$rc $(execs) $(ls "$S"/.prod/evidence/*.json 2>/dev/null | wc -l | tr -d ' ')"
(cd "$S" && EVIDENCE_CLEAN_ENV=1 MAKEFLAGS=n EVIDENCE_RUN_ID=r1 EVIDENCE_RESULTS="$RES" bash scripts/evidence-record.sh --run gates >/dev/null 2>&1); rc=$?
check "dry run: even entered past the clean re-exec (marker preset), the recorder refuses on its own (2, nothing ran)" "2 0" "$rc $(execs)"
rm -f "$S"/.prod/evidence/*.json
(cd "$S" && EVIDENCE_CLEAN_ENV=1 MAKEFLAGS=n EVIDENCE_RUN_ID=r1 EVIDENCE_RESULTS="$RES" bash scripts/evidence-record.sh --attest >/dev/null 2>&1); rc=$?
check "dry run: marker preset, --attest: the recorder refuses on its own (2) and writes NO record file" "2 0" "$rc $(ls "$S"/.prod/evidence/*.json 2>/dev/null | wc -l | tr -d ' ')"
(cd "$S" && MAKEFLAGS=-Otarget EVIDENCE_RUN_ID=r1 EVIDENCE_RESULTS="$RES" bash scripts/evidence-record.sh --run g-one >/dev/null 2>&1); check "dry run: MAKEFLAGS=-Otarget is NOT a dry run (no false refusal): runs" "0 1" "$? $(execs)"

# ---- the clean environment, through the recorder and through a real make ---------------------------
SE="$T/repoe"; build "$SE" '"g-dump|bash gates/dump.sh"'
printf '#!/usr/bin/env bash\n{ env | sort; echo "TYPE_GREP=$(type -t grep)"; echo "GLOB=$(echo gates/*.sh)"; } > "%s/dump"\n' "$T" > "$SE/gates/dump.sh"
printf 'export SKIP_FROM_BE=1\n' > "$T/be.sh"
printf '.PHONY: gates\ngates:\n\t@bash scripts/evidence-record.sh --run gates\n' > "$SE/Makefile"
git -C "$SE" add -A; git -C "$SE" -c user.email=t@t -c user.name=t commit -q -m mk
dumpseen() { grep -c "^$1=" "$T/dump" 2>/dev/null | tr -d ' '; }
rm -f "$T/dump"; (cd "$SE" && SKIP=1 make --no-print-directory gates >/dev/null 2>&1)
check "env via make: SKIP=1 make gates -> the gate runs (control) and does not see SKIP" "present 0" "$(present "$T/dump") $(dumpseen SKIP)"
rm -f "$T/dump"; (cd "$SE" && env SKIP=1 BASH_ENV="$T/be.sh" SHELLOPTS=xtrace GLOBIGNORE='*' CDPATH=/tmp IFS=x bash scripts/evidence-record.sh --run gates >/dev/null 2>&1)
check "env via the recorder: SKIP, BASH_ENV (not sourced), SHELLOPTS, GLOBIGNORE, CDPATH, IFS do not reach the gate" "0 0 0 0 0 0 0" "$(dumpseen SKIP) $(dumpseen BASH_ENV) $(dumpseen SKIP_FROM_BE) $(dumpseen SHELLOPTS) $(dumpseen GLOBIGNORE) $(dumpseen CDPATH) $(dumpseen IFS)"
rm -f "$T/dump"; (cd "$SE" && bash -c 'grep() { echo hijack; }; export -f grep; bash scripts/evidence-record.sh --run gates' >/dev/null 2>&1)
check "env via the recorder: an exported function named grep does not reach the gate" "TYPE_GREP=file" "$(grep '^TYPE_GREP=' "$T/dump")"
printf '.PHONY: gates\ngates: export SKIP := 1\ngates: export BASH_ENV := %s\ngates:\n\t@bash scripts/evidence-record.sh --run gates\n' "$T/be.sh" > "$SE/Makefile"
rm -f "$T/dump"; (cd "$SE" && make --no-print-directory gates FOO=bar >/dev/null 2>&1)
check "env via make: a target-specific export / BASH_ENV / MAKEFLAGS / MAKELEVEL never reach the gate" "0 0 0 0 0" "$(dumpseen SKIP) $(dumpseen BASH_ENV) $(dumpseen SKIP_FROM_BE) $(dumpseen MAKEFLAGS) $(dumpseen MAKELEVEL)"
rm -f "$T/dump"; (cd "$SE" && CLAUDE_CONFIG_DIR=/cfg EVIDENCE_RUN_ID=r1 EVIDENCE_RESULTS="$T/res-env.tsv" bash scripts/evidence-record.sh --run gates >/dev/null 2>&1)
check "env via the recorder: an allowlisted name DOES reach the gate (non-vacuity)" "/cfg r1" "$(sed -n 's/^CLAUDE_CONFIG_DIR=//p' "$T/dump") $(sed -n 's/^EVIDENCE_RUN_ID=//p' "$T/dump")"

# ---- the round-2 forgeries, VERBATIM: Makefile-only edits that each produced an attested PASS for a failing gate
# The gate fails unless SKIP is set; the Makefile is the ONLY thing edited. With the recorder owning
# execution nothing reads the Makefile and the environment is cleaned, so none can yield attested PASS.
SF="$T/repof"; build "$SF" '"g-real|bash gates/real.sh"'
printf '#!/usr/bin/env bash\necho real >> "%s"\n[ -n "${SKIP:-}" ] && exit 0\necho real-gate-fails\nexit 1\n' "$LOG" > "$SF/gates/real.sh"
printf 'export SKIP_FROM_BE=1\nexport SKIP=1\n' > "$SF/be.sh"
git -C "$SF" add -A; git -C "$SF" -c user.email=t@t -c user.name=t commit -q -m real
BASEMK='.PHONY: gates evidence\ngates:\n\t@bash scripts/evidence-record.sh --run gates\nevidence:\n\t@bash scripts/evidence-record.sh --attest\n'
forge() { # name, extra Makefile text (printf %b), optional GNUmakefile text
  local name="$1" extra="$2" gnu="${3:-}"
  fresh "f-$name"; rm -f "$SF/GNUmakefile"
  printf "$BASEMK$extra" > "$SF/Makefile"
  [ -z "$gnu" ] || printf "$gnu" > "$SF/GNUmakefile"
  (cd "$SF" && EVIDENCE_RUN_ID=r1 EVIDENCE_RESULTS="$RES" make --no-print-directory gates >/dev/null 2>&1); local rg=$?
  (cd "$SF" && rm -f .prod/evidence/*.json && EVIDENCE_RUN_ID=r1 EVIDENCE_RESULTS="$RES" make --no-print-directory evidence >/dev/null 2>&1); local re=$?
  local att; att=$(grep -c '"verdict": "PASS"' "$SF"/.prod/evidence/*.json | awk -F: '{s+=$NF} END{print s+0}')
  # make exits 2 when a recipe fails; an edit that stops the runner being called can make `make gates` exit 0 (nothing ran),
  # which is exactly why the evidence step must fail on its own: the record has no line to attest and EXECUTES the gate
  check "forgery: $name -> make evidence fails (rc!=0, make gates rc=$rg) and the record holds no PASS" "1 0" "$([ "$re" != 0 ] && echo 1 || echo "rc=$re") $att"
}
forge 'x gates: export SKIP := 1' 'x gates: export SKIP := 1\n'
forge 'x gates: export BASH_ENV := (a file exporting SKIP)' "x gates: export BASH_ENV := $SF/be.sh\n"
forge 'x gates: with a second recipe' 'x gates:\n\t@true\n'
forge 'T := gates / $(T): export SKIP := 1' 'T := gates\n$(T): export SKIP := 1\n'
forge 'RUN += --quiet junk -- env SKIP=1 bash scripts/run-once.sh' 'RUN += --quiet junk -- env SKIP=1 bash scripts/run-once.sh\n'
forge '$(eval RUN := env SKIP=1 bash scripts/run-once.sh)' '$(eval RUN := env SKIP=1 bash scripts/run-once.sh)\n'
forge 'a committed GNUmakefile that make prefers over Makefile' '' '.PHONY: gates evidence\ngates:\n\t@SKIP=1 bash scripts/evidence-record.sh --run gates\nevidence:\n\t@SKIP=1 bash scripts/evidence-record.sh --attest\n'
rm -f "$SF/GNUmakefile"; printf "$BASEMK" > "$SF/Makefile"
fresh f-ctl; (cd "$SF" && EVIDENCE_RUN_ID=r1 EVIDENCE_RESULTS="$RES" make --no-print-directory gates >/dev/null 2>&1); rc=$?
check "forgery control: the unedited Makefile also fails the gate (the failure is real, not caused by the edit)" 1 "$([ "$rc" != 0 ] && echo 1 || echo 0)"
# a Makefile that never calls the runner: no lines exist, attest EXECUTES (slow, true)
fresh f-none; rm -f "$SF"/.prod/evidence/*.json; printf '.PHONY: gates\ngates:\n\t@true\n' > "$SF/Makefile"
(cd "$SF" && EVIDENCE_RUN_ID=r1 EVIDENCE_RESULTS="$RES" bash scripts/evidence-record.sh --attest >/dev/null 2>&1); rc=$?
check "a Makefile that does not call the runner leaves no line: --attest EXECUTES the gate and it FAILs" "1 1 0" "$rc $(grep -c '"source": "executed"' "$SF"/.prod/evidence/*.json) $(grep -c '"source": "attested"' "$SF"/.prod/evidence/*.json)"

# ---- label instead of what ran, and a recorded `true` for a real failing gate (reviewer forgery B2) --
S6="$T/repo6"; build "$S6" '"g-real|bash gates/real.sh"'
printf '#!/usr/bin/env bash\necho real >> "%s"\necho real-gate-fails\nexit 1\n' "$LOG" > "$S6/gates/real.sh"
git -C "$S6" add -A; git -C "$S6" -c user.email=t@t -c user.name=t commit -q -m real
fresh f
rod "$S6" --as 'bash gates/real.sh' g-real -- true >"$T/o6a" 2>&1; rc=$?
check "forgery: \`--as '<label>' g-real -- true\` is refused by the runner (2), no line" "2 absent" "$rc $(present "$RES")"
rod "$S6" g-real -- true >/dev/null 2>&1
base=$(execs); erd "$S6" --attest >"$T/o6" 2>&1; rc=$?
check "forgery: a recorded \`true\` for g-real is NOT attested: executed, and the real gate FAILs" "1 1 0 1" "$rc $(nrecd "$S6" '"source": "executed"') $(nrecd "$S6" '"source": "attested"') $(( $(execs) - base ))"
check "forgery: ...the record says FAIL for g-real" 1 "$(grep -c '"gate": "g-real".*"verdict": "FAIL"' "$S6"/.prod/evidence/*.json)"
fresh f2; (cd "$S6" && EVIDENCE_RUN_ID=r1 EVIDENCE_RESULTS="$RES" bash scripts/evidence-record.sh --run gates >/dev/null 2>&1); rc=$?
check "mutation guard: a gate that fails is recorded as exit 1 by the runner that executed it (not a PASS line)" "1 1" "$rc $(cut -f4 "$RES")"

# ---- canonical argv: spaces / quotes / dollar / semicolon, a glob, a bash -c loop -------------------
S4="$T/repo4"
build "$S4" '"g-one|bash gates/one.sh"' \
  '"g-loop|bash -c '\''for d in gates; do [ -d \"\$d\" ] || continue; done; echo loop-ok'\''"' \
  '"g-glob|bash gates/glob.sh gates/*.sh"' \
  $'"g-args|bash gates/arg.sh \'a b\' \'\\$HOME\' \'x;y\'"'
printf '#!/usr/bin/env bash\necho x >> "%s"\necho "glob-args $#"\n' "$LOG" > "$S4/gates/glob.sh"
printf '#!/usr/bin/env bash\necho x >> "%s"\necho "args $#"\n' "$LOG" > "$S4/gates/arg.sh"
git -C "$S4" add -A; git -C "$S4" -c user.email=t@t -c user.name=t commit -q -m gates
fresh d; (cd "$S4" && EVIDENCE_RUN_ID=r1 EVIDENCE_RESULTS="$RES" bash scripts/evidence-record.sh --run gates >/dev/null 2>&1); rc=$?
base=$(execs); erd "$S4" --attest >"$T/o4" 2>&1; rc2=$?
check "canonical: the loop, the glob and the quoted args written by --run are ATTESTED by --attest, none re-run" "0 0 4 0 0" "$rc $rc2 $(nrecd "$S4" '"source": "attested"') $(nrecd "$S4" '"source": "executed"') $(( $(execs) - base ))"
check "canonical: the command column of the glob gate is the EXPANDED argv" "bash gates/glob.sh gates/arg.sh gates/bad.sh gates/glob.sh gates/one.sh gates/two.sh" "$(awk -F'\t' '$2=="g-glob"{print $3}' "$RES")"
fresh d3; (cd "$S4" && env GLOBIGNORE='*' BASHOPTS=nullglob EVIDENCE_RUN_ID=r1 EVIDENCE_RESULTS="$RES" bash scripts/evidence-record.sh --run g-glob >/dev/null 2>&1)
check "clean self: GLOBIGNORE / BASHOPTS exported by the caller do not change how a GATES glob expands (recorded argv is the full one)" "bash gates/glob.sh gates/arg.sh gates/bad.sh gates/glob.sh gates/one.sh gates/two.sh" "$(awk -F'\t' '$2=="g-glob"{print $3}' "$RES")"
fresh d2
rod "$S4" g-one -- bash gates/one.sh >/dev/null 2>&1
rod "$S4" g-loop -- bash -c 'for d in gates; do [ -d "$d" ] || continue; done; echo DIFFERENT' >/dev/null 2>&1
rod "$S4" g-glob -- bash gates/glob.sh gates/one.sh >/dev/null 2>&1
rod "$S4" g-args -- bash gates/arg.sh 'a' 'b' '$HOME' 'x;y' >/dev/null 2>&1
erd "$S4" --attest >"$T/o4" 2>&1
check "canonical: another loop body, another glob expansion, args split differently -> executed" "1 3" "$(nrecd "$S4" '"source": "attested"') $(nrecd "$S4" '"source": "executed"')"

# ---- probe-selftests: derived from per-suite lines of THIS run, and the ONE suite list -------------
S5="$T/repo5"
R_PRE_IDS='' R_AGG_IDS='probe-selftests' build "$S5" '"g-one|bash gates/one.sh"' '"probe-selftests|bash gates/agg.sh"'
printf '#!/usr/bin/env bash\necho x >> "%s"\necho agg-ran\nexit 1\n' "$LOG" > "$S5/gates/agg.sh"
mkdir -p "$S5/_shared/probes/tests" "$S5/scripts/tests" "$S5/tpl"
for sf in _shared/probes/a-selftest.sh _shared/probes/tests/b-selftest.sh scripts/tests/c-selftest.sh tpl/t-selftest.sh; do
  printf '#!/usr/bin/env bash\necho x >> "%s"\necho "3 ok, 0 failed"\nexit "$(cat %s.rc 2>/dev/null || echo 0)"\n' "$LOG" "${sf%.sh}" > "$S5/$sf"
done
printf 'scripts/tests/*.rc\n_shared/probes/*.rc\ntpl/*.rc\n' >> "$S5/.git/info/exclude"
mk5() { # $1 = SUITE_GLOBS body, $2 = SUITE_REQUIRED body, $3 = SUITE_TEMPLATE body
  R_SUITE_GLOBS="$1" R_SUITE_REQUIRED="$2" R_SUITE_TEMPLATE="$3" R_PRE_IDS='' R_AGG_IDS='probe-selftests' R_GATES=$(printf '  %s\n' '"g-one|bash gates/one.sh"' '"probe-selftests|bash gates/agg.sh"') mkrec "$S5/scripts/evidence-record.sh"; }
G3="  '_shared/probes/*-selftest.sh'
  '_shared/probes/tests/*-selftest.sh'
  'scripts/tests/*-selftest.sh'"
mk5 "$G3" "  _shared/probes/a-selftest.sh" "  tpl/t-selftest.sh"
git -C "$S5" add -A; git -C "$S5" -c user.email=t@t -c user.name=t commit -q -m base5
SUITES5=(_shared/probes/a-selftest.sh _shared/probes/tests/b-selftest.sh scripts/tests/c-selftest.sh tpl/t-selftest.sh)
rec5() { local s; for s in "$@"; do rod "$S5" --quiet --count "selftest:$s" -- bash "$s" >/dev/null 2>&1; done; }
fresh s0; (cd "$S5" && bash scripts/evidence-record.sh --run selftests >"$T/o5" 2>&1); rc=$?
check "selftests: --run selftests runs exactly the resolved suites, globs first then the template ones, in order" "0 4" "$rc $(execs)"
check "selftests: ...the suites printed ok and the total is stated" "4 1" "$(grep -c ' ok$' "$T/o5") $(grep -c '^selftests: 4 passed' "$T/o5")"
fresh s0b; echo 1 > "$S5/scripts/tests/c-selftest.rc"; (cd "$S5" && bash scripts/evidence-record.sh --run selftests >"$T/o5" 2>&1); rc=$?; rm -f "$S5/scripts/tests/c-selftest.rc"
check "selftests: a failing suite stops the run (exit 1), prints its output tail, later suites do not run" "1 3 1" "$rc $(execs) $(grep -c '3 ok, 0 failed' "$T/o5")"
fresh s1; rod "$S5" g-one -- bash gates/one.sh >/dev/null 2>&1; (cd "$S5" && EVIDENCE_RUN_ID=r1 EVIDENCE_RESULTS="$RES" bash scripts/evidence-record.sh --run selftests >/dev/null 2>&1); base=$(execs)
erd "$S5" --attest >"$T/o5" 2>&1; rc=$?
check "selftests: every suite has its own line -> probe-selftests ATTESTED, nothing re-executed" "0 2 0 0" "$rc $(nrecd "$S5" '"source": "attested"') $(nrecd "$S5" '"source": "executed"') $(( $(execs) - base ))"
check "selftests: ...derived from the four suite lines, named in the record" 1 "$(nrecd "$S5" '"derived_from_suites": 4')"
fresh s2
rod "$S5" g-one -- bash gates/one.sh >/dev/null 2>&1
rod "$S5" probe-selftests -- bash gates/agg.sh >/dev/null 2>&1
erd "$S5" --attest >"$T/o5" 2>&1
check "forgery: an aggregate line alone is NEVER attested -> probe-selftests executed" "1 1" "$(nrecd "$S5" '"source": "executed"') $(nrecd "$S5" '"source": "attested"')"
check "forgery: ...and the record names the missing suite line" 1 "$(nrecd "$S5" '"why_executed": "suite _shared/probes/a-selftest.sh: no-line-for-this-id-command-tree-run"')"
fresh s3; rod "$S5" g-one -- bash gates/one.sh >/dev/null 2>&1; rec5 _shared/probes/a-selftest.sh _shared/probes/tests/b-selftest.sh tpl/t-selftest.sh
erd "$S5" --attest >"$T/o5" 2>&1
check "selftests: ONE suite without a line -> probe-selftests executed, the other gate attested" "1 1" "$(nrecd "$S5" '"source": "executed"') $(nrecd "$S5" '"source": "attested"')"
check "selftests: ...and the record names the suite" 1 "$(nrecd "$S5" '"why_executed": "suite scripts/tests/c-selftest.sh: no-line-for-this-id-command-tree-run"')"
fresh s4; rod "$S5" g-one -- bash gates/one.sh >/dev/null 2>&1; rec5 _shared/probes/a-selftest.sh _shared/probes/tests/b-selftest.sh tpl/t-selftest.sh
echo 1 > "$S5/scripts/tests/c-selftest.rc"; rec5 scripts/tests/c-selftest.sh; rm -f "$S5/scripts/tests/c-selftest.rc"; base=$(execs)
erd "$S5" --attest >"$T/o5" 2>&1; rc=$?
check "selftests: a recorded FAILING suite -> probe-selftests attested FAIL (exit 1), not re-run" "1 $base" "$rc $(execs)"
check "selftests: ...the evidence names the suite and its exit code" 1 "$(nrecd "$S5" '"evidence": "failing suite(s): scripts/tests/c-selftest.sh (exit 1)"')"
fresh s5; rod "$S5" g-one -- bash gates/one.sh >/dev/null 2>&1; rec5 "${SUITES5[@]}"; RUN=r2
erd "$S5" --attest >"$T/o5" 2>&1; RUN=r1
check "selftests: lines of ANOTHER run -> everything executed, nothing attested" "2 0" "$(nrecd "$S5" '"source": "executed"') $(nrecd "$S5" '"source": "attested"')"
fresh s6; rod "$S5" g-one -- bash gates/one.sh >/dev/null 2>&1; rec5 _shared/probes/a-selftest.sh _shared/probes/tests/b-selftest.sh tpl/t-selftest.sh
rod "$S5" --quiet --count "selftest:scripts/tests/c-selftest.sh" -- bash -c 'echo "3 ok"' >/dev/null 2>&1
erd "$S5" --attest >"$T/o5" 2>&1
check "selftests: a suite line recorded under another argv (bash -c ...) does not count" "1 1" "$(nrecd "$S5" '"source": "executed"') $(nrecd "$S5" '"source": "attested"')"
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
fresh s11; rod "$S5" g-one -- bash gates/one.sh >/dev/null 2>&1; rec5 "${SUITES5[@]}"
erd "$S5" --attest >"$T/o5" 2>&1
check "selftests: attest over a broken suite list does NOT derive probe-selftests from lines (executed)" "1 1" "$(nrecd "$S5" '"source": "executed"') $(nrecd "$S5" '"why_executed": "suite-list: ')"
mk5 "$G3" "  _shared/probes/a-selftest.sh" "  tpl/t-selftest.sh"

# ---- the runner edited between --run and --attest voids the lines even where git cannot see it -----
SX="$T/repox"; build "$SX" "${GATES2[@]}"
printf 'scripts/run-once.sh\n' >> "$SX/.git/info/exclude"; git -C "$SX" rm -q --cached scripts/run-once.sh; git -C "$SX" -c user.email=t@t -c user.name=t commit -q -m untrack
fresh x; (cd "$SX" && EVIDENCE_RUN_ID=r1 EVIDENCE_RESULTS="$RES" bash scripts/evidence-record.sh --run gates >/dev/null 2>&1)
(cd "$SX" && rm -f .prod/evidence/*.json && EVIDENCE_RUN_ID=r1 EVIDENCE_RESULTS="$RES" bash scripts/evidence-record.sh --attest >/dev/null 2>&1)
check "runner hash: untouched runner -> the lines of --run are attested (control)" 2 "$(nrecd "$SX" '"source": "attested"')"
echo '# edited after the run' >> "$SX/scripts/run-once.sh"; : > "$LOG"
(cd "$SX" && rm -f .prod/evidence/*.json && EVIDENCE_RUN_ID=r1 EVIDENCE_RESULTS="$RES" bash scripts/evidence-record.sh --attest >/dev/null 2>&1)
check "runner hash: the runner edited between --run and --attest (git cannot see it) -> both executed" "2 0" "$(execs) $(nrecd "$SX" '"source": "attested"')"

# ---- the real file: the trust model, and the shape the rest of the repo pins ---------------------
check "header: the trust-model paragraph is present in evidence-record.sh" 1 "$(grep -c '^# TRUST MODEL (three sentences' "$root/scripts/evidence-record.sh")"
real_ids=$(sed -n '/^GATES=(/,/^)/p' "$root/scripts/evidence-record.sh" | grep -vE '^[[:space:]]*#' | sed -nE 's/^[[:space:]]*"([A-Za-z0-9_-]+)\|.*"[[:space:]]*$/\1/p')
check "real GATES: every entry is two-field id|command and ids are unique" "$(printf '%s\n' "$real_ids" | grep -c .)" "$(printf '%s\n' "$real_ids" | sort -u | grep -c .)"
grp=$(grep -E '^(PRE_IDS|POST_IDS|AGG_IDS)=\(' "$root/scripts/evidence-record.sh" | sed -E 's/^[A-Z_]+=\((.*)\)/\1/' | tr ' ' '\n' | grep .)
miss=""; for g in $grp; do [[ $'\n'"$real_ids"$'\n' == *$'\n'"$g"$'\n'* ]] || miss="$miss $g"; done
check "real GATES: every PRE/POST/AGG id names a real gate (a typo would silently move a gate to main)" "" "$miss"
check "real GATES: the main group (what make gates runs) is the 18 gates make gates ran before" "18" "$(printf '%s\n' "$real_ids" | grep -vxFf <(printf '%s\n' $grp) | grep -c .)"

if (( FAILED > 0 )); then echo "evidence-record selftest: $FAILED of $CASES case(s) FAILED"; exit 1; fi
echo "evidence-record selftest: $CASES case(s) passed"
