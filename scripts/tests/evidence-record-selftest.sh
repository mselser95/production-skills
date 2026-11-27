#!/usr/bin/env bash
# evidence-record-selftest.sh -- scripts/evidence-record.sh --attest takes a gate from the
# run-once results file ONLY for a same-id, same-command, same-tree, same-run well-formed line,
# otherwise executes it, and says which in the record; a recorded failure fails the record; the
# GATES-covers-`make gates` guard and the run-once id/command cross-check still fire.
# provenance: candidate; ttl: 2027-02-27; pinning: true
# Hermetic: fake gates are tiny scripts in a scratch git repo; the real GATES array is replaced
# in a scratch COPY of the script, everything else in it is the real code.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
unset EVIDENCE_RESULTS EVIDENCE_RUN_ID EVIDENCE_MAX_AGE
T=$(mktemp -d) || exit 2
trap 'rm -rf "$T"' EXIT
LOG="$T/exec.log"; export EXEC_LOG="$LOG"

CASES=0; FAILED=0
check() { CASES=$((CASES+1)); if [ "$2" = "$3" ]; then printf '  ok   %-72s %s\n' "$1" "$3"
  else printf '  FAIL %-72s expected=%s actual=%s\n' "$1" "$2" "$3"; FAILED=$((FAILED+1)); fi; }

# build <dir> <GATES body lines...>: scratch repo with the REAL evidence-record.sh and run-once.sh,
# the GATES array replaced, a Makefile whose `gates:` runs the same gates through the runner.
build() {
  local d="$1"; shift
  mkdir -p "$d/scripts" "$d/gates" "$d/.prod"; echo keep > "$d/.prod/keep"
  cp "$root/scripts/run-once.sh" "$d/scripts/run-once.sh"
  printf '  %s\n' "$@" > "$d/.garr"
  awk -v f="$d/.garr" '/^GATES=\(/ {print "GATES=("; while ((getline l < f) > 0) print l; print ")"; skip=1; next} skip && /^\)/ {skip=0; next} !skip {print}' \
    "$root/scripts/evidence-record.sh" > "$d/scripts/evidence-record.sh"; rm -f "$d/.garr"
  printf '#!/usr/bin/env bash\necho x >> "$EXEC_LOG"\necho "%s summary"\n' ok-one > "$d/gates/one.sh"
  printf '#!/usr/bin/env bash\necho x >> "$EXEC_LOG"\necho "%s summary"\n' ok-two > "$d/gates/two.sh"
  printf '#!/usr/bin/env bash\necho x >> "$EXEC_LOG"\necho "bad summary"\nexit 1\n' > "$d/gates/bad.sh"
  {
    printf 'RUN := bash scripts/run-once.sh\n.PHONY: gates\ngates:\n'
    printf '\t@$(RUN) g-one -- bash gates/one.sh\n\t@$(RUN) g-two -- bash gates/two.sh\n\n'
  } > "$d/Makefile"
  echo "tracked" > "$d/tracked.txt"
  git -C "$d" init -q . && git -C "$d" add -A && git -C "$d" -c user.email=t@t -c user.name=t commit -q -m base
}
GATES2=('"g-one|bash gates/one.sh"' '"g-two|bash gates/two.sh"')
S="$T/repo"; build "$S" "${GATES2[@]}"

ro()  { (cd "$S" && EVIDENCE_RESULTS="$RES" EVIDENCE_RUN_ID="${RUN:-r1}" bash scripts/run-once.sh "$@"); }
er()  { (cd "$S" && rm -f .prod/evidence/*.json && EVIDENCE_RESULTS="$RES" EVIDENCE_RUN_ID="${RUN:-r1}" bash scripts/evidence-record.sh "$@"); }
rec() { cat "$S"/.prod/evidence/*.json; }
nrec() { grep -c "$1" "$S"/.prod/evidence/*.json | awk -F: '{s+=$NF} END{print s+0}'; }
execs() { grep -c . "$LOG" 2>/dev/null || echo 0; }
fresh() { RES="$T/res-$1.tsv"; RUN=r1; rm -f "$RES" "$LOG"; : > "$LOG"; }
record_both() { ro g-one -- bash gates/one.sh >/dev/null 2>&1; ro g-two -- bash gates/two.sh >/dev/null 2>&1; }

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

# ---- executed when it does not ---------------------------------------------------------------
fresh b
er --attest >"$T/o" 2>&1; rc=$?
check "no results file -> both executed, exit 0" "0 2 2" "$rc $(nrec '"source": "executed"') $(execs)"
check "no results file -> the record says why" 2 "$(nrec '"why_executed": "no-results-file"')"
fresh b2; : > "$RES"; er --attest >/dev/null 2>&1
check "empty results file -> both executed" "2 2" "$(nrec '"source": "executed"') $(execs)"
fresh b3; record_both; printf 'garbage\n' >> "$RES"; base=$(execs); er --attest >/dev/null 2>&1
check "malformed line in the file -> BOTH gates executed, none attested" "2 0" "$(( $(execs) - base )) $(nrec '"source": "attested"')"
fresh b4; record_both; base=$(execs); git -C "$S" -c user.email=t@t -c user.name=t commit -q --allow-empty -m other-head
er --attest >/dev/null 2>&1
check "another HEAD -> both executed" "2 0" "$(( $(execs) - base )) $(nrec '"source": "attested"')"
fresh b5; ro g-one -- bash gates/one.sh >/dev/null 2>&1; ro --as 'bash gates/two.sh --different' g-two -- bash gates/two.sh >/dev/null 2>&1; base=$(execs)
er --attest >/dev/null 2>&1
check "command string differs for ONE gate -> only that gate executed" "1 1 1" "$(( $(execs) - base )) $(nrec '"source": "executed"') $(nrec '"source": "attested"')"
fresh b6; record_both; echo more >> "$S/tracked.txt"; base=$(execs); er --attest >"$T/o" 2>&1
check "tree dirty-state differs (clean when run, dirty now) -> both executed" "2 0" "$(( $(execs) - base )) $(nrec '"source": "attested"')"
check "a dirty tree names the record so it cannot be mistaken for an attestation" 1 "$(find "$S/.prod/evidence" -name 'dirty-*.json' | grep -c .)"
git -C "$S" checkout -q -- tracked.txt
fresh b7; record_both; RUN=r2; base=$(execs); er --attest >/dev/null 2>&1; RUN=r1
check "another run id -> both executed" "2 0" "$(( $(execs) - base )) $(nrec '"source": "attested"')"
fresh b8; record_both; base=$(execs); er >/dev/null 2>&1
check "without --attest everything executes even with a valid results file (today's behaviour)" "2 2" "$(( $(execs) - base )) $(nrec '"source": "executed"')"
check "without --attest the record says attest_mode false" 1 "$(nrec '"attest_mode": false')"

# ---- failures --------------------------------------------------------------------------------
fresh c; ro --as 'bash gates/one.sh' g-one -- false >/dev/null 2>&1; ro g-two -- bash gates/two.sh >/dev/null 2>&1; base=$(execs)
er --attest >"$T/o" 2>&1; rc=$?
check "a recorded failure fails the record (exit 1)" 1 "$rc"
check "...it is NOT re-executed to see whether it passes now" "$base" "$(execs)"
check "...the record has one FAIL and one PASS" "1 1" "$(nrec '"verdict": "FAIL"') $(nrec '"verdict": "PASS"')"
check "...and the verdict line says INCOMPLETE" 1 "$(grep -c 'VERDICT: INCOMPLETE -- 1 gate(s) failed' "$T/o")"
fresh c2; record_both
ro --as 'bash gates/one.sh' g-one -- false >/dev/null 2>&1; base=$(execs)
er --attest >"$T/o" 2>&1; rc=$?
check "conflicting lines for one id -> that gate executed (and passes)" "0 1 1" "$rc $(nrec '"source": "executed"') $(( $(execs) - base ))"
check "...the record names the conflict" 1 "$(nrec '"why_executed": "conflicting-lines-for-this-id"')"
fresh c3; record_both; ro other-id -- false >/dev/null 2>&1; base=$(execs)
er --attest >/dev/null 2>&1; rc=$?
check "a failing line for an id that is NOT in GATES is ignored" "0 0" "$rc $(( $(execs) - base ))"
S2="$T/repo2"
build "$S2" '"g-one|bash gates/one.sh"' '"g-bad|bash gates/bad.sh"'
printf 'RUN := bash scripts/run-once.sh\n.PHONY: gates\ngates:\n\t@$(RUN) g-one -- bash gates/one.sh\n\t@$(RUN) g-bad -- bash gates/bad.sh\n\n' > "$S2/Makefile"
git -C "$S2" add -A; git -C "$S2" -c user.email=t@t -c user.name=t commit -q -m mk
(cd "$S2" && bash scripts/evidence-record.sh --attest >"$T/o2" 2>&1); rc=$?
check "an EXECUTED failing gate fails the record too (exit 1)" 1 "$rc"
check "...with the failure named FAIL in the record" 1 "$(grep -c '"gate": "g-bad".*"verdict": "FAIL"' "$S2"/.prod/evidence/*.json)"

# ---- the guards ------------------------------------------------------------------------------
S3="$T/repo3"; build "$S3" "${GATES2[@]}"
printf 'RUN := bash scripts/run-once.sh\n.PHONY: gates\ngates:\n\t@$(RUN) g-one -- bash gates/one.sh\n\t@$(RUN) g-two -- bash gates/two.sh\n\t@bash gates/extra.sh\n\n' > "$S3/Makefile"
git -C "$S3" add -A; git -C "$S3" -c user.email=t@t -c user.name=t commit -q -m extra
(cd "$S3" && bash scripts/evidence-record.sh --attest >"$T/o3" 2>&1); rc=$?
check "GATES guard: a script in make gates missing from GATES -> exit 2" 2 "$rc"
check "...naming it" 1 "$(grep -c 'uncovered: extra.sh' "$T/o3")"
printf 'RUN := bash scripts/run-once.sh\n.PHONY: gates\ngates:\n\t@$(RUN) g-one -- bash gates/one.sh\n\t@$(RUN) g-two -- bash gates/two.sh\n\t@$(RUN) g-three -- bash gates/extra.sh\n\n' > "$S3/Makefile"
(cd "$S3" && bash scripts/evidence-record.sh --check-wiring >"$T/o3" 2>&1); rc=$?
check "GATES guard: the same script behind the RUNNER is still seen (run-once.sh itself is not the gate)" "2 1" "$rc $(grep -c 'uncovered: extra.sh' "$T/o3")"
printf 'RUN := bash scripts/run-once.sh\n.PHONY: gates\ngates:\n\t@$(RUN) g-one -- bash gates/one.sh\n\t@$(RUN) g-two -- bash gates/two.sh\n\n' > "$S3/Makefile"
(cd "$S3" && bash scripts/evidence-record.sh --check-wiring >"$T/o3" 2>&1); rc=$?
check "the guard stays quiet when every gate is covered (exit 0)" 0 "$rc"
printf 'RUN := bash scripts/run-once.sh\n.PHONY: gates\ngates:\n\t@$(RUN) g-one -- bash gates/one.sh\n\t@$(RUN) g-two -- bash gates/two.sh arg\n\n' > "$S3/Makefile"
(cd "$S3" && bash scripts/evidence-record.sh --check-wiring >"$T/o3" 2>&1); rc=$?
check "cross-check: make gates runs a gate under another command string than GATES -> exit 2" "2 1" "$rc $(grep -c 'drift: g-two' "$T/o3")"
printf 'RUN := bash scripts/run-once.sh\n.PHONY: gates\ngates:\n\t@$(RUN) g-one -- bash gates/one.sh\n\t@$(RUN) g-two -- bash gates/two.sh\n\t@$(RUN) not-listed -- bash gates/one.sh arg\n\n' > "$S3/Makefile"
(cd "$S3" && bash scripts/evidence-record.sh --check-wiring >"$T/o3" 2>&1); rc=$?
check "cross-check: a runner id that is not in GATES is not a drift" 0 "$rc"
(cd "$S3" && bash scripts/evidence-record.sh --bogus >"$T/o3" 2>&1); check "an unknown argument is refused (2)" 2 "$?"

# ---- the real repo's own wiring --------------------------------------------------------------
(cd "$root" && bash scripts/evidence-record.sh --check-wiring >"$T/o4" 2>&1); rc=$?
check "the REAL Makefile gates: and GATES agree (ids, command strings, coverage)" "0" "$rc"
R="$T/real"; mkdir -p "$R/scripts"; cp "$root/scripts/evidence-record.sh" "$root/scripts/run-once.sh" "$R/scripts/"
sed 's|-- bash $(PROBES)/skill-weight.sh|-- bash $(PROBES)/skill-weight.sh extra|' "$root/Makefile" > "$R/Makefile"
(cd "$R" && git init -q . && bash scripts/evidence-record.sh --check-wiring >"$T/o5" 2>&1); rc=$?
check "mutated REAL Makefile (skill-weight command string changed) -> exit 2" "2 1" "$rc $(grep -c 'drift: skill-weight' "$T/o5")"
grep -v 'row-catalogue\.sh' "$root/scripts/evidence-record.sh" > "$R/scripts/evidence-record.sh"
cp "$root/Makefile" "$R/Makefile"
(cd "$R" && bash scripts/evidence-record.sh --check-wiring >"$T/o5" 2>&1); rc=$?
check "REAL Makefile with row-catalogue.sh missing from GATES -> exit 2" "2 1" "$rc $(grep -c 'uncovered: row-catalogue.sh' "$T/o5")"

if (( FAILED > 0 )); then echo "evidence-record selftest: $FAILED of $CASES case(s) FAILED"; exit 1; fi
echo "evidence-record selftest: $CASES case(s) passed"
