#!/usr/bin/env bash
# evidence-record-selftest.sh -- scripts/evidence-record.sh --attest takes a gate from the
# run-once results file ONLY for a same-id, same-command (canonical argv), same-tree, same-run
# well-formed line, otherwise executes it, and says which in the record; a recorded failure
# fails the record; `probe-selftests` is attested only from per-suite lines of the same run;
# the wiring check reads the Makefile as text and refuses any recipe line that is not exactly
# `@$(RUN) <id> -- <command>` (env prefix, - / + prefix, || true, a second command, ...).
# provenance: candidate; ttl: 2027-02-27; pinning: true
# Hermetic: fake gates are tiny scripts in a scratch git repo; the real GATES array is replaced
# in a scratch COPY of the script, everything else in it is the real code.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
unset EVIDENCE_RESULTS EVIDENCE_RUN_ID EVIDENCE_MAX_AGE MAKEFLAGS MFLAGS
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
  printf '#!/usr/bin/env bash\necho x >> "$EXEC_LOG"\necho "%s summary"\nexit "${ONE_RC:-0}"\n' ok-one > "$d/gates/one.sh"
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
# the same two, in another scratch repo ($1)
rod() { local d="$1"; shift; (cd "$d" && EVIDENCE_RESULTS="$RES" EVIDENCE_RUN_ID="${RUN:-r1}" bash scripts/run-once.sh "$@"); }
erd() { local d="$1"; shift; (cd "$d" && rm -f .prod/evidence/*.json && EVIDENCE_RESULTS="$RES" EVIDENCE_RUN_ID="${RUN:-r1}" bash scripts/evidence-record.sh "$@"); }
nrec() { grep -c "$1" "$S"/.prod/evidence/*.json | awk -F: '{s+=$NF} END{print s+0}'; }
nrecd() { local d="$1"; shift; grep -c "$1" "$d"/.prod/evidence/*.json | awk -F: '{s+=$NF} END{print s+0}'; }
execs() { local n; n=$(grep -c . "$LOG" 2>/dev/null); echo "${n:-0}"; }
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
fresh b5; ro g-one -- bash gates/one.sh >/dev/null 2>&1; ro g-two -- bash gates/two.sh --different >/dev/null 2>&1; base=$(execs)
er --attest >/dev/null 2>&1
check "argv differs for ONE gate (an extra argument) -> only that gate executed" "1 1 1" "$(( $(execs) - base )) $(nrec '"source": "executed"') $(nrec '"source": "attested"')"
fresh b6; record_both; echo more >> "$S/tracked.txt"; base=$(execs); er --attest >"$T/o" 2>&1
check "tree dirty-state differs (clean when run, dirty now) -> both executed" "2 0" "$(( $(execs) - base )) $(nrec '"source": "attested"')"
check "a dirty tree names the record so it cannot be mistaken for an attestation" 1 "$(find "$S/.prod/evidence" -name 'dirty-*.json' | grep -c .)"
git -C "$S" checkout -q -- tracked.txt
fresh b7; record_both; RUN=r2; base=$(execs); er --attest >/dev/null 2>&1; RUN=r1
check "another run id -> both executed" "2 0" "$(( $(execs) - base )) $(nrec '"source": "attested"')"
fresh b8; record_both; base=$(execs); er >/dev/null 2>&1
check "without --attest everything executes even with a valid results file (today's behaviour)" "2 2" "$(( $(execs) - base )) $(nrec '"source": "executed"')"
check "without --attest the record says attest_mode false" 1 "$(nrec '"attest_mode": false')"
fresh b9; record_both; base=$(execs)
(cd "$S" && rm -f .prod/evidence/*.json && env -u EVIDENCE_RUN_ID EVIDENCE_RESULTS="$RES" bash scripts/evidence-record.sh --attest >"$T/o" 2>&1); rc=$?
check "no run id at attest time -> both executed (a local run attests nothing)" "0 2 2" "$rc $(nrec '"source": "executed"') $(( $(execs) - base ))"
check "...and the record says why" 2 "$(nrec '"why_executed": "no-run-id"')"
fresh b10
(cd "$S" && env -u EVIDENCE_RUN_ID EVIDENCE_RESULTS="$RES" bash scripts/run-once.sh g-one -- bash gates/one.sh >/dev/null 2>&1)
(cd "$S" && rm -f .prod/evidence/*.json && EVIDENCE_RUN_ID=r1 EVIDENCE_RESULTS="$RES" bash scripts/evidence-record.sh --attest >/dev/null 2>&1)
check "a gate run WITHOUT a run id left no line, so a later attest finds nothing to trust" "0 2" "$(nrec '"source": "attested"') $(nrec '"source": "executed"')"

# ---- failures --------------------------------------------------------------------------------
fresh c; ONE_RC=1 ro g-one -- bash gates/one.sh >/dev/null 2>&1; ro g-two -- bash gates/two.sh >/dev/null 2>&1; base=$(execs)
er --attest >"$T/o" 2>&1; rc=$?
check "a recorded failure fails the record (exit 1)" 1 "$rc"
check "...it is NOT re-executed to see whether it passes now" "$base" "$(execs)"
check "...the record has one FAIL and one PASS" "1 1" "$(nrec '"verdict": "FAIL"') $(nrec '"verdict": "PASS"')"
check "...and the verdict line says INCOMPLETE" 1 "$(grep -c 'VERDICT: INCOMPLETE -- 1 gate(s) failed' "$T/o")"
fresh c2; record_both
ONE_RC=1 ro g-one -- bash gates/one.sh >/dev/null 2>&1; base=$(execs)
er --attest >"$T/o" 2>&1; rc=$?
check "conflicting lines for one id -> that gate executed (and passes)" "0 1 1" "$rc $(nrec '"source": "executed"') $(( $(execs) - base ))"
check "...the record names the conflict" 1 "$(nrec '"why_executed": "conflicting-lines-for-this-id"')"
fresh c3; record_both; ro other-id -- bash gates/bad.sh >/dev/null 2>&1; base=$(execs)
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

# ---- the recipe grammar: every line of `gates:` is exactly `@$(RUN) <id> -- <command>` ---------
# Each variant is a `gates:` body (printf %b: \t, \n). g-one is always well-formed; the next
# line is the forgery. The wiring check reads TEXT, it never runs make, so none of these runs.
G1='\t@$(RUN) g-one -- bash gates/one.sh\n'
wf() { printf 'RUN := bash scripts/run-once.sh\n.PHONY: gates\ngates:\n%b' "$1" > "$S3/Makefile"
       (cd "$S3" && bash scripts/evidence-record.sh --check-wiring >"$T/o3" 2>&1); echo $?; }
declare -a FORGERIES=(
  'env prefix|\t@SKIP=1 $(RUN) g-two -- bash gates/two.sh\n'
  'minus prefix|\t-@$(RUN) g-two -- bash gates/two.sh\n'
  'minus after @|\t@-$(RUN) g-two -- bash gates/two.sh\n'
  'plus prefix|\t+@$(RUN) g-two -- bash gates/two.sh\n'
  'plus after @|\t@+$(RUN) g-two -- bash gates/two.sh\n'
  'or-true after the runner|\t@$(RUN) g-two -- bash gates/two.sh || true\n'
  'or-true before the runner|\t@true || $(RUN) g-two -- bash gates/two.sh\n'
  'semicolon, a second command|\t@$(RUN) g-two -- bash gates/two.sh; echo done\n'
  '&& a second command|\t@$(RUN) g-two -- bash gates/two.sh && bash gates/one.sh\n'
  'a pipe|\t@$(RUN) g-two -- bash gates/two.sh | cat\n'
  'a redirection|\t@$(RUN) g-two -- bash gates/two.sh > /dev/null\n'
  'a backtick|\t@$(RUN) g-two -- bash gates/two.sh `true`\n'
  'a $(shell)|\t@$(RUN) g-two -- bash gates/two.sh $(shell true)\n'
  '$(MAKE) as the gate|\t@$(RUN) g-two -- $(MAKE) -s two.sh\n'
  'the gate bare, no runner|\t@bash gates/two.sh\n'
  'a bare second line|\t@$(RUN) g-two -- bash gates/two.sh\n\t@echo gates/two.sh\n'
  'a continuation|\t@$(RUN) g-two -- bash gates/two.sh \\\n\t  extra\n'
  'an unclosed quote|\t@$(RUN) g-two -- bash -c "gates/two.sh\n'
  'a blank line before the forged one|\n\t@SKIP=1 $(RUN) g-two -- bash gates/two.sh\n'
  'a comment line before the forged one|# note\n\t@SKIP=1 $(RUN) g-two -- bash gates/two.sh\n'
  'a nested $(MAKE) on a recorder line|\t@$(RUN) g-two -- bash gates/two.sh\n\t@$(MAKE) $(RUN) x\n'
  'a second gates: rule|\t@$(RUN) g-two -- bash gates/two.sh\ngates: extra\n\t@true\n'
  'RUN redefined|\t@$(RUN) g-two -- bash gates/two.sh\nRUN := true\n'
  'SHELL redefined|\t@$(RUN) g-two -- bash gates/two.sh\nSHELL := /bin/sh\n'
  'export|\t@$(RUN) g-two -- bash gates/two.sh\nexport SKIP := 1\n'
  '.ONESHELL|\t@$(RUN) g-two -- bash gates/two.sh\n.ONESHELL:\n'
  'a conditional|\t@$(RUN) g-two -- bash gates/two.sh\nifdef CI\nendif\n'
)
for f in "${FORGERIES[@]}"; do
  name="${f%%|*}"; body="${f#*|}"
  rc=$(wf "$G1$body"); w=$(grep -c 'wiring:' "$T/o3")
  check "recipe grammar: $name -> exit 2 and a wiring error" "2 yes" "$rc $([ "$w" -ge 1 ] && echo yes || echo no)"
done
rc=$(wf "$G1"'\t@$(RUN) g-two -- bash gates/two.sh\n')
check "recipe grammar: the clean two-line recipe passes (the forgeries above were real)" "0" "$rc"
printf 'RUN := bash scripts/run-once.sh\n.PHONY: gates check-fast\ncheck-fast:\n\t@$(RUN) g-one -- bash gates/one.sh\n\t@$(MAKE) --no-print-directory gates\ngates:\n\t@$(RUN) g-two -- bash gates/two.sh\n' > "$S3/Makefile"
(cd "$S3" && bash scripts/evidence-record.sh --check-wiring >"$T/o3" 2>&1); rc=$?
check "recipe grammar: check-fast may hold the one allowlisted hop to gates" 0 "$rc"
printf 'RUN := bash scripts/run-once.sh\n.PHONY: gates check-fast\ncheck-fast:\n\t@SKIP=1 $(RUN) g-one -- bash gates/one.sh\n\t@$(MAKE) --no-print-directory gates\ngates:\n\t@$(RUN) g-two -- bash gates/two.sh\n' > "$S3/Makefile"
(cd "$S3" && bash scripts/evidence-record.sh --check-wiring >"$T/o3" 2>&1); rc=$?
check "recipe grammar: an env-prefixed recorder line in check-fast is refused too" "2" "$rc"
printf 'RUN := bash scripts/run-once.sh\n.PHONY: gates check-fast\ncheck-fast:\n\t@$(RUN) g-one -- bash gates/one.sh\n\t@$(MAKE) --no-print-directory gates || true\ngates:\n\t@$(RUN) g-two -- bash gates/two.sh\n' > "$S3/Makefile"
(cd "$S3" && bash scripts/evidence-record.sh --check-wiring >"$T/o3" 2>&1); rc=$?
check "recipe grammar: the allowlist is by EXACT text (the hop with || true is refused)" "2" "$rc"

# ---- canonical argv: spaces / quotes / dollar / semicolon, a glob, a bash -c loop, $(PROBES) ----
S4="$T/repo4"
build "$S4" '"g-one|bash gates/one.sh"' \
  '"g-loop|bash -c '\''for d in gates; do [ -d \"\$d\" ] || continue; done; echo loop-ok'\''"' \
  '"g-glob|bash gates/glob.sh gates/*.sh"' \
  $'"g-args|bash gates/arg.sh \'a b\' \'\\$HOME\' \'x;y\'"' \
  '"g-pr|bash gates/pr.sh"'
printf '#!/usr/bin/env bash\necho x >> "$EXEC_LOG"\necho "glob-args $#"\n' > "$S4/gates/glob.sh"
printf '#!/usr/bin/env bash\necho x >> "$EXEC_LOG"\necho "args $#"\n' > "$S4/gates/arg.sh"
printf '#!/usr/bin/env bash\necho x >> "$EXEC_LOG"\necho pr-ok\n' > "$S4/gates/pr.sh"
{ printf 'RUN := bash scripts/run-once.sh\nPROBES := gates\n.PHONY: gates\ngates:\n'
  printf '\t@$(RUN) g-one -- bash gates/one.sh\n'
  printf '\t@$(RUN) g-loop -- bash -c '"'"'for d in gates; do [ -d "$$d" ] || continue; done; echo loop-ok'"'"'\n'
  printf '\t@$(RUN) g-glob -- bash gates/glob.sh gates/*.sh\n'
  printf '\t@$(RUN) g-args -- bash gates/arg.sh '"'"'a b'"'"' '"'"'$$HOME'"'"' '"'"'x;y'"'"'\n'
  printf '\t@$(RUN) g-pr -- bash $(PROBES)/pr.sh\n\n'
} > "$S4/Makefile"
git -C "$S4" add -A; git -C "$S4" -c user.email=t@t -c user.name=t commit -q -m gates
(cd "$S4" && bash scripts/evidence-record.sh --check-wiring >"$T/o4a" 2>&1); rc=$?
check "canonical: a Makefile with a bash -c loop, a glob, quoted args and \$(PROBES) is consistent with GATES" "0" "$rc"
fresh d
rod "$S4" g-one -- bash gates/one.sh >/dev/null 2>&1
rod "$S4" g-loop -- bash -c 'for d in gates; do [ -d "$d" ] || continue; done; echo loop-ok' >/dev/null 2>&1
(cd "$S4" && EVIDENCE_RESULTS="$RES" EVIDENCE_RUN_ID=r1 bash scripts/run-once.sh g-glob -- bash gates/glob.sh gates/*.sh >/dev/null 2>&1)
rod "$S4" g-args -- bash gates/arg.sh 'a b' '$HOME' 'x;y' >/dev/null 2>&1
rod "$S4" g-pr -- bash gates/pr.sh >/dev/null 2>&1
base=$(execs); erd "$S4" --attest >"$T/o4" 2>&1; rc=$?
check "canonical: the loop, the expanded glob, quoted args and \$(PROBES) gates are ATTESTED, none re-run" "0 5 0 0" "$rc $(nrecd "$S4" '"source": "attested"') $(nrecd "$S4" '"source": "executed"') $(( $(execs) - base ))"
check "canonical: the command column of the glob gate is the EXPANDED argv" "bash gates/glob.sh gates/arg.sh gates/bad.sh gates/glob.sh gates/one.sh gates/pr.sh gates/two.sh" "$(awk -F'\t' '$2=="g-glob"{print $3}' "$RES")"
fresh d2
rod "$S4" g-one -- bash gates/one.sh >/dev/null 2>&1
rod "$S4" g-loop -- bash -c 'for d in gates; do [ -d "$d" ] || continue; done; echo DIFFERENT' >/dev/null 2>&1
(cd "$S4" && EVIDENCE_RESULTS="$RES" EVIDENCE_RUN_ID=r1 bash scripts/run-once.sh g-glob -- bash gates/glob.sh gates/one.sh >/dev/null 2>&1)
rod "$S4" g-args -- bash gates/arg.sh 'a' 'b' '$HOME' 'x;y' >/dev/null 2>&1
rod "$S4" g-pr -- bash gates/pr.sh >/dev/null 2>&1
erd "$S4" --attest >"$T/o4" 2>&1
check "canonical: another loop body, another glob expansion, args split differently -> executed" "2 3" "$(nrecd "$S4" '"source": "attested"') $(nrecd "$S4" '"source": "executed"')"

# ---- the canonical form has one definition in effect: evidence-record's canon_var == run-once.sh canon ----
eval "$(sed -n '/^canon_var()/p' "$root/scripts/evidence-record.sh")"
agree=0; total=0
for argv in "bash|-c|for d in a/*; do echo \"\$d\"; done" "a b|it's|\$HOME|x;y|*" "|empty first" "tab	in|new
line" "unicode-é|back\\slash"; do
  IFS='|' read -r -a av <<<"$argv"; total=$((total+1))
  canon_var "${av[@]}"; [ "$CANON" = "$(bash "$root/scripts/run-once.sh" canon "${av[@]}")" ] && agree=$((agree+1))
done
check "canonical: evidence-record's quoting equals run-once.sh's on awkward argv" "$total" "$agree"

# ---- reviewer forgery B2: a label instead of what ran -----------------------------------------
S6="$T/repo6"
build "$S6" '"g-real|bash gates/real.sh"'
printf '#!/usr/bin/env bash\necho x >> "$EXEC_LOG"\necho real-gate-fails\nexit 1\n' > "$S6/gates/real.sh"
printf 'RUN := bash scripts/run-once.sh\n.PHONY: gates\ngates:\n\t@$(RUN) g-real -- bash gates/real.sh\n\n' > "$S6/Makefile"
git -C "$S6" add -A; git -C "$S6" -c user.email=t@t -c user.name=t commit -q -m real
fresh f
rod "$S6" --as 'bash gates/real.sh' g-real -- true >"$T/o6a" 2>&1; rc=$?
check "forgery: \`--as '<label>' g-real -- true\` is refused by the recorder (2), no line" "2 absent" "$rc $([ -e "$RES" ] && echo present || echo absent)"
rod "$S6" g-real -- true >/dev/null 2>&1
base=$(execs); erd "$S6" --attest >"$T/o6" 2>&1; rc=$?
check "forgery: a recorded \`true\` for g-real is NOT attested: executed, and the real gate FAILs" "1 1 0 1" "$rc $(nrecd "$S6" '"source": "executed"') $(nrecd "$S6" '"source": "attested"') $(( $(execs) - base ))"
check "forgery: ...the record says FAIL for g-real" 1 "$(grep -c '"gate": "g-real".*"verdict": "FAIL"' "$S6"/.prod/evidence/*.json)"

# ---- reviewer forgery B3: an env prefix neuters the gate, the cross-check used to skip the line --
printf 'RUN := bash scripts/run-once.sh\n.PHONY: gates\ngates:\n\t@SKIP=1 $(RUN) g-real -- bash gates/real.sh\n\n' > "$S6/Makefile"
fresh f2
rod "$S6" g-real -- bash gates/real.sh >/dev/null 2>&1
rm -f "$S6"/.prod/evidence/*.json
erd "$S6" --attest >"$T/o6" 2>&1; rc=$?
check "forgery: \`@SKIP=1 \$(RUN) g-real -- ...\` -> the attest run is refused (2), no record" "2 0" "$rc $(ls "$S6"/.prod/evidence/*.json 2>/dev/null | wc -l | tr -d ' ')"
check "forgery: ...and the wiring error names the line" 1 "$(grep -c 'wiring:.*SKIP=1' "$T/o6")"

# ---- reviewer forgery B1: probe-selftests derived from per-suite lines of THIS run --------------
S5="$T/repo5"
build "$S5" '"g-one|bash gates/one.sh"' '"probe-selftests|make --no-print-directory selftests"'
mkdir -p "$S5/_shared/probes/tests" "$S5/scripts/tests"
for sf in _shared/probes/a-selftest.sh _shared/probes/tests/b-selftest.sh scripts/tests/c-selftest.sh; do
  printf '#!/usr/bin/env bash\necho x >> "$EXEC_LOG"\necho "3 ok, 0 failed"\nexit "${SUITE_RC:-0}"\n' > "$S5/$sf"
done
mk5() { # $1 = SELFTEST_GLOBS third glob, $2 = REQUIRED, $3 = selftests recipe
  { printf 'RUN := bash scripts/run-once.sh\nPROBES := _shared/probes\nTEMPLATE_SELFTESTS =\n'
    printf 'REQUIRED_SELFTESTS = %s\n' "$2"
    printf 'SELFTEST_GLOBS = $(PROBES)/*-selftest.sh $(PROBES)/tests/*-selftest.sh %s $(TEMPLATE_SELFTESTS)\n' "$1"
    printf '.PHONY: gates selftests\ngates:\n\t@$(RUN) g-one -- bash gates/one.sh\n\nselftests:\n%b\n' "$3"
  } > "$S5/Makefile"; }
LOOP5='\t@for t in $(SELFTEST_GLOBS); do [ -f "$$t" ] || continue; $(RUN) --quiet --count "selftest:$$t" -- bash "$$t" || exit 1; done'
mk5 'scripts/tests/*-selftest.sh' '$(PROBES)/a-selftest.sh' "$LOOP5"
git -C "$S5" add -A; git -C "$S5" -c user.email=t@t -c user.name=t commit -q -m base5
SUITES5=(_shared/probes/a-selftest.sh _shared/probes/tests/b-selftest.sh scripts/tests/c-selftest.sh)
rec5() { local s; for s in "$@"; do rod "$S5" --quiet --count "selftest:$s" -- bash "$s" >/dev/null 2>&1; done; }
(cd "$S5" && bash scripts/evidence-record.sh --check-wiring >"$T/o5" 2>&1); rc=$?
check "selftests: the scratch Makefile with all three suites in its list is consistent" 0 "$rc"
fresh s1; rod "$S5" g-one -- bash gates/one.sh >/dev/null 2>&1; rec5 "${SUITES5[@]}"; base=$(execs)
erd "$S5" --attest >"$T/o5" 2>&1; rc=$?
check "selftests: every suite has its own line -> probe-selftests ATTESTED, nothing re-executed" "0 2 0 0" "$rc $(nrecd "$S5" '"source": "attested"') $(nrecd "$S5" '"source": "executed"') $(( $(execs) - base ))"
check "selftests: ...derived from the three suite lines, named in the record" 1 "$(nrecd "$S5" '"derived_from_suites": 3')"
fresh s2
mk5 'scripts/tests/*-selftest.sh' '$(PROBES)/a-selftest.sh' '\t@true'
rod "$S5" g-one -- bash gates/one.sh >/dev/null 2>&1
rod "$S5" probe-selftests -- make --no-print-directory selftests >/dev/null 2>&1
check "forgery: a recipe that runs no suite still writes an AGGREGATE line (the old hole)" "1" "$(grep -c "probe-selftests" "$RES")"
erd "$S5" --attest >"$T/o5" 2>&1
check "forgery: an aggregate line alone is NEVER attested -> probe-selftests executed" "1 1" "$(nrecd "$S5" '"source": "executed"') $(nrecd "$S5" '"source": "attested"')"
check "forgery: ...and the record names the missing suite line" 1 "$(nrecd "$S5" '"why_executed": "suite _shared/probes/a-selftest.sh: no-line-for-this-id-command-tree-run"')"
mk5 'scripts/tests/*-selftest.sh' '$(PROBES)/a-selftest.sh' "$LOOP5"
fresh s3; rod "$S5" g-one -- bash gates/one.sh >/dev/null 2>&1; rec5 _shared/probes/a-selftest.sh _shared/probes/tests/b-selftest.sh
erd "$S5" --attest >"$T/o5" 2>&1
check "selftests: ONE suite without a line -> probe-selftests executed, the other gate attested" "1 1" "$(nrecd "$S5" '"source": "executed"') $(nrecd "$S5" '"source": "attested"')"
check "selftests: ...and the record names the suite" 1 "$(nrecd "$S5" '"why_executed": "suite scripts/tests/c-selftest.sh: no-line-for-this-id-command-tree-run"')"
fresh s4; rod "$S5" g-one -- bash gates/one.sh >/dev/null 2>&1; rec5 _shared/probes/a-selftest.sh _shared/probes/tests/b-selftest.sh
SUITE_RC=1 rec5 scripts/tests/c-selftest.sh; base=$(execs)
erd "$S5" --attest >"$T/o5" 2>&1; rc=$?
check "selftests: a recorded FAILING suite -> probe-selftests attested FAIL (exit 1), not re-run" "1 $base" "$rc $(execs)"
check "selftests: ...the evidence names the suite and its exit code" 1 "$(nrecd "$S5" '"evidence": "failing suite(s): scripts/tests/c-selftest.sh (exit 1)"')"
fresh s5; rod "$S5" g-one -- bash gates/one.sh >/dev/null 2>&1; rec5 "${SUITES5[@]}"; RUN=r2
erd "$S5" --attest >"$T/o5" 2>&1; RUN=r1
check "selftests: lines of ANOTHER run -> everything executed, nothing attested" "2 0" "$(nrecd "$S5" '"source": "executed"') $(nrecd "$S5" '"source": "attested"')"
fresh s6; rod "$S5" g-one -- bash gates/one.sh >/dev/null 2>&1; rec5 _shared/probes/a-selftest.sh _shared/probes/tests/b-selftest.sh
rod "$S5" --quiet --count "selftest:scripts/tests/c-selftest.sh" -- bash -c 'echo "3 ok"' >/dev/null 2>&1
erd "$S5" --attest >"$T/o5" 2>&1
check "selftests: a suite line recorded under another argv (bash -c ...) does not count" "1 1" "$(nrecd "$S5" '"source": "executed"') $(nrecd "$S5" '"source": "attested"')"
fresh s7; rm -f "$T/dry5.tsv"
(cd "$S5" && EVIDENCE_RUN_ID=r1 EVIDENCE_RESULTS="$T/dry5.tsv" make -n selftests >/dev/null 2>&1); rc=$?
check "selftests: \`make -n selftests\` exits 0 and writes no line" "0 absent" "$rc $([ -e "$T/dry5.tsv" ] && echo present || echo absent)"
# wiring: a suite dropped from the glob, a required suite not in it, a smuggling recipe
mk5 'scripts/nothing/*-selftest.sh' '$(PROBES)/a-selftest.sh' "$LOOP5"
(cd "$S5" && bash scripts/evidence-record.sh --check-wiring >"$T/o5" 2>&1); rc=$?
check "selftests: a suite under the fixed directories that the glob no longer runs -> exit 2" "2 1" "$rc $(grep -c 'wiring: selftests: scripts/tests/c-selftest.sh' "$T/o5")"
mk5 'scripts/tests/*-selftest.sh' '$(PROBES)/a-selftest.sh $(PROBES)/zz-selftest.sh' "$LOOP5"
(cd "$S5" && bash scripts/evidence-record.sh --check-wiring >"$T/o5" 2>&1); rc=$?
check "selftests: a REQUIRED suite that the glob does not resolve to -> exit 2" "2 1" "$rc $(grep -c 'required suite _shared/probes/zz-selftest.sh' "$T/o5")"
mk5 'scripts/tests/*-selftest.sh' '$(PROBES)/a-selftest.sh' '\t@$(RUN) --quiet probe-selftests -- $(MAKE) selftests-run'
(cd "$S5" && bash scripts/evidence-record.sh --check-wiring >"$T/o5" 2>&1); rc=$?
check "selftests: a recorder line with \$(MAKE) anywhere in the Makefile -> exit 2" "2 1" "$rc $(grep -c 'recorder line holds \$(MAKE)' "$T/o5")"
mk5 'scripts/tests/*-selftest.sh' '$(PROBES)/a-selftest.sh' '\t+@$(RUN) --quiet probe-selftests -- true'
(cd "$S5" && bash scripts/evidence-record.sh --check-wiring >"$T/o5" 2>&1); rc=$?
check "selftests: a recorder line starting with + anywhere in the Makefile -> exit 2" "2 1" "$rc $(grep -c 'recorder line starts with +' "$T/o5")"

# ---- the real repo's own wiring --------------------------------------------------------------
(cd "$root" && bash scripts/evidence-record.sh --check-wiring >"$T/o4" 2>&1); rc=$?
check "the REAL Makefile gates: and GATES agree (ids, command strings, coverage, grammar, suites)" "0" "$rc"
R="$T/real"; mkdir -p "$R/scripts"; cp "$root/scripts/evidence-record.sh" "$root/scripts/run-once.sh" "$R/scripts/"
ln -s "$root/_shared" "$R/_shared"; ln -s "$root/prod-new" "$R/prod-new"; ln -s "$root/scripts/tests" "$R/scripts/tests"
(cd "$R" && git init -q .)
rw() { (cd "$R" && bash scripts/evidence-record.sh --check-wiring >"$T/o5" 2>&1); echo $?; }
cp "$root/Makefile" "$R/Makefile"; check "REAL Makefile copy passes in the scratch root (control)" 0 "$(rw)"
sed 's#-- bash $(PROBES)/skill-weight.sh#-- bash $(PROBES)/skill-weight.sh extra#' "$root/Makefile" > "$R/Makefile"
rc=$(rw); check "mutated REAL Makefile (skill-weight command string changed) -> exit 2" "2 1" "$rc $(grep -c 'drift: skill-weight' "$T/o5")"
sed 's#@$(RUN) skill-weight --#@SKIP=1 $(RUN) skill-weight --#' "$root/Makefile" > "$R/Makefile"
rc=$(rw); check "mutated REAL Makefile (env prefix on the skill-weight line) -> exit 2 naming it" "2 1" "$rc $(grep -c 'wiring:.*SKIP=1.*skill-weight' "$T/o5")"
sed 's#@$(RUN) policy-coverage -- bash $(PROBES)/policy-coverage.sh#& || true#' "$root/Makefile" > "$R/Makefile"
rc=$(rw); check "mutated REAL Makefile (|| true on the policy-coverage line) -> exit 2 naming it" "2 1" "$rc $(grep -c 'wiring:.*policy-coverage.*|| true' "$T/o5")"
sed 's#@$(RUN) ci-workflows-valid#@+$(RUN) ci-workflows-valid#' "$root/Makefile" > "$R/Makefile"
rc=$(rw); check "mutated REAL Makefile (+ prefix on the check-fast line) -> exit 2" "2 yes" "$rc $([ "$(grep -c 'wiring:.*ci-workflows-valid' "$T/o5")" -ge 1 ] && echo yes || echo no)"
sed 's# scripts/tests/\*-selftest.sh##' "$root/Makefile" > "$R/Makefile"
rc=$(rw); check "mutated REAL Makefile (scripts/tests dropped from SELFTEST_GLOBS) -> exit 2 naming a suite" "2 1" "$rc $([ "$(grep -c 'wiring: selftests: scripts/tests/.*-selftest.sh' "$T/o5")" -ge 1 ] && echo 1 || echo 0)"
cp "$root/Makefile" "$R/Makefile"
grep -v 'row-catalogue\.sh' "$root/scripts/evidence-record.sh" > "$R/scripts/evidence-record.sh"
rc=$(rw); check "REAL Makefile with row-catalogue.sh missing from GATES -> exit 2" "2 1" "$rc $(grep -c 'uncovered: row-catalogue.sh' "$T/o5")"

if (( FAILED > 0 )); then echo "evidence-record selftest: $FAILED of $CASES case(s) FAILED"; exit 1; fi
echo "evidence-record selftest: $CASES case(s) passed"
