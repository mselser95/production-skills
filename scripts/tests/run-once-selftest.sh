#!/usr/bin/env bash
# run-once-selftest.sh -- scripts/run-once.sh runs a command in a CLEAN ENVIRONMENT (env -i plus a
# fixed allowlist: nothing a caller or a Makefile exported reaches it), records one line per run,
# derived from what it EXECUTED (the canonical argv, never a caller-supplied label), only with an
# explicit run id and never under make -n/-q/-t (MAKEFLAGS read the way make writes it); and
# vouches for a recorded result ONLY when the id, the command string, the tree identity, the run
# id, the environment-allowlist hash and the runner hash all match a strictly well-formed line,
# with no conflicting duplicate.
# provenance: candidate; ttl: 2027-02-27; pinning: true
# Hermetic: a scratch git repo holding a copy of the script; no network, no repo suite re-run.
# No case reads a Makefile of this repo: the Makefile is not part of the trust path.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
unset EVIDENCE_RESULTS EVIDENCE_RUN_ID EVIDENCE_MAX_AGE MAKEFLAGS MFLAGS
T=$(mktemp -d) || exit 2
trap 'rm -rf "$T"' EXIT
S="$T/repo"; mkdir -p "$S/scripts" "$S/gates" "$T/out"
cp "$root/scripts/run-once.sh" "$S/scripts/run-once.sh"
mkdir -p "$S/.prod"; echo keep > "$S/.prod/keep"
printf '#!/usr/bin/env bash\nexit "$(cat gates/x.rc 2>/dev/null || echo 0)"\n' > "$S/gates/x.sh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$S/gates/y.sh"
printf '#!/usr/bin/env bash\necho "$(cat gates/cnt.n 2>/dev/null || echo 0) ok"\n' > "$S/gates/cnt.sh"
git -C "$S" init -q . && printf 'gates/*.rc\ngates/*.n\n' >> "$S/.git/info/exclude" && git -C "$S" add -A && git -C "$S" -c user.email=t@t -c user.name=t commit -q -m base || exit 2
echo "tracked" > "$S/tracked.txt"; git -C "$S" add tracked.txt && git -C "$S" -c user.email=t@t -c user.name=t commit -q -m tracked

CASES=0; FAILED=0
check() { CASES=$((CASES+1)); if [ "$2" = "$3" ]; then printf '  ok   %-70s %s\n' "$1" "$3"
  else printf '  FAIL %-70s expected=%s actual=%s\n' "$1" "$2" "$3"; FAILED=$((FAILED+1)); fi; }
ro()  { (cd "$S" && EVIDENCE_RESULTS="$RES" EVIDENCE_RUN_ID="${RUN:-r1}" bash scripts/run-once.sh "$@"); }
# rr: the read-only subcommands (resolve / counts / canon / tree-id) from an ALREADY CLEAN environment, so the runner's clean start
# (one more exec per call) is not paid ~100 times; the clean start has its own cases below
rr()  { (cd "$S" && env -i PATH="$PATH" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" EVIDENCE_RESULTS="$RES" EVIDENCE_RUN_ID="${RUN:-r1}" bash scripts/run-once.sh "$@"); }
res() { rr resolve "$1" "$2" | cut -f1,2 | tr '\t' ' '; }       # kind + (rc | reason)
res2() { res "$1" "$2" | awk '{print $1 " " $2}'; }            # kind + first word of the reason
kind() { rr resolve "$1" "$2" | cut -f1; }
fresh() { RES="$T/res-$1.tsv"; RUN=r1; rm -f "$RES"; }
commit() { git -C "$S" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "$1"; }
present() { [ -e "$1" ] && echo present || echo absent; }

# ---- recording ------------------------------------------------------------------------------
fresh rec
ro g1 -- bash -c 'echo hello; echo "12 ok, 0 failed"' >"$T/out/o1" 2>&1; rc=$?
check "run: exit code of the command is passed through (0)" 0 "$rc"
check "run: the command's output is shown (tee)" 2 "$(wc -l <"$T/out/o1" | tr -d ' ')"
check "run: exactly one line is recorded" 1 "$(wc -l <"$RES" | tr -d ' ')"
check "run: the line has fourteen tab-separated columns" 14 "$(awk -F'\t' '{print NF}' "$RES")"
check "run: column 1 is the format tag, column 2 the id" "v3 g1" "$(cut -f1,2 "$RES" | tr '\t' ' ')"
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
ro g8 -- bash -c 'printf "a\tb\n"' >/dev/null 2>&1; check "run: a plain command whose OUTPUT has a tab is recorded (1 line)" 1 "$(grep -c "^v3.g8" "$RES")"
ro g9 -- printf '%s' $'a\tb' >/dev/null 2>&1; rc=$?
check "run: an argv holding a TAB is recorded in quoted form: exit 0, still fourteen columns" "0 14" "$rc $(awk -F'\t' '$2=="g9"{print NF}' "$RES")"

# ---- the recorded command IS the executed argv, canonically quoted (no --as label) -----------
fresh canon
ro --as 'bash gates/real.sh' c0 -- true >/dev/null 2>&1; rc=$?
check "run: --as is gone: refused (2), nothing recorded" "2 absent" "$rc $(present "$RES")"
ro e1 -- bash -c 'printf "%s" "a\\nb"' >/dev/null 2>&1
exp_e1=$(printf '%q ' bash -c 'printf "%s" "a\\nb"'); exp_e1=${exp_e1% }
check "canon: a command with backslashes matches itself exactly (no awk escape processing)" "attested" "$(kind e1 "$exp_e1")"
ro e2 -- printf '%s' 'a b' "it's" '$HOME' '*' 'x;y' >/dev/null 2>&1
check "canon: spaces, a quote, a dollar, a glob and a semicolon are each quoted" "printf %s a\\ b it\\'s \\\$HOME \\* x\\;y" "$(awk -F'\t' '$2=="e2"{print $3}' "$RES")"
ro e3 -- bash -c 'for d in /nonexistent/*; do :; done; echo hi' >/dev/null 2>&1
check "canon: a bash -c loop is the quoted argv, in full" 'bash -c for\ d\ in\ /nonexistent/\*\;\ do\ :\;\ done\;\ echo\ hi' "$(awk -F'\t' '$2=="e3"{print $3}' "$RES")"
check "canon: ...and that string is attested" "attested" "$(kind e3 'bash -c for\ d\ in\ /nonexistent/\*\;\ do\ :\;\ done\;\ echo\ hi')"
check "canon: the unquoted spelling of the same argv is NOT what is recorded" "miss" "$(kind e3 "bash -c for d in /nonexistent/*; do :; done; echo hi")"
check "canon: the subcommand quotes an argv the same way" "printf %s a\\ b it\\'s \\\$HOME \\* x\\;y" "$(rr canon printf '%s' 'a b' "it's" '$HOME' '*' 'x;y')"
mkdir -p "$S/globd"; : > "$S/globd/one.txt"; : > "$S/globd/two.txt"; git -C "$S" add -A globd 2>/dev/null; commit globd
(cd "$S" && EVIDENCE_RESULTS="$RES" EVIDENCE_RUN_ID=r1 bash scripts/run-once.sh e4 -- true globd/*.txt >/dev/null 2>&1)
check "canon: a glob is recorded AFTER the shell expanded it (what ran)" "true globd/one.txt globd/two.txt" "$(awk -F'\t' '$2=="e4"{print $3}' "$RES")"

# ---- make dry run / question / touch: nothing runs, nothing is recorded -----------------------
fresh dry
for mf in n 'nw -- VAR=x' '-n' '--dry-run' '--just-print' '--recon' '--question' '--touch' q t kn 'wn --no-print-directory' 'w -n'; do
  rm -f "$RES" "$T/ran"
  MAKEFLAGS="$mf" ro dr -- bash -c "echo ran > '$T/ran'" >"$T/out/dr" 2>&1; rc=$?
  check "dry run: MAKEFLAGS='$mf' -> exit 2, command not run, nothing recorded, one line" "2 absent absent 1" "$rc $(present "$RES") $(present "$T/ran") $(wc -l <"$T/out/dr" | tr -d ' ')"
done
rm -f "$RES"; MFLAGS=-n ro dr -- true >/dev/null 2>&1; rc=$?
check "dry run: MFLAGS=-n -> exit 2, nothing recorded" "2 absent" "$rc $(present "$RES")"
for mf in w s '-j4 --jobserver-auth=3,4' 'k -- X=n' '-- RUN=nqt' 's --no-print-directory' '--warn-undefined-variables' '-Otarget' '-Iinc' '-j4 -l2.5' '-ofile.txt' ' --jobserver-auth=3,4'; do
  rm -f "$RES"; MAKEFLAGS="$mf" ro dr -- true >/dev/null 2>&1; rc=$?
  check "dry run: MAKEFLAGS='$mf' is NOT a dry run -> recorded" "0 present" "$rc $(present "$RES")"
done
# a real make: a recorder line holding $(MAKE) is executed by GNU make under -n; run-once must refuse it
MM="$T/mk2"; mkdir -p "$MM/scripts"; cp "$root/scripts/run-once.sh" "$MM/scripts/run-once.sh"
printf 'RUN := bash scripts/run-once.sh\n.PHONY: x inner\nx:\n\t@$(RUN) agg -- $(MAKE) --no-print-directory inner\ninner:\n\t@true\n' > "$MM/Makefile"
git -C "$MM" init -q . && git -C "$MM" add -A && git -C "$MM" -c user.email=t@t -c user.name=t commit -q -m base
rm -f "$T/mm.tsv"; (cd "$MM" && EVIDENCE_RUN_ID=m1 EVIDENCE_RESULTS="$T/mm.tsv" make --no-print-directory x >/dev/null 2>&1); rc=$?
check "make (control): the same recipe run for real records the aggregate line" "0 present" "$rc $(present "$T/mm.tsv")"
rm -f "$T/mm.tsv"; (cd "$MM" && EVIDENCE_RUN_ID=m1 EVIDENCE_RESULTS="$T/mm.tsv" make -n --no-print-directory x >/dev/null 2>&1); rc=$?
check "make -n: the \$(MAKE) recorder line executes, run-once refuses: non-zero, NO line written" "1 absent" "$([ "$rc" != 0 ] && echo 1 || echo 0) $(present "$T/mm.tsv")"

# ---- no run id: the command runs, nothing is recorded, nothing is attestable -------------------
fresh noid
(cd "$S" && EVIDENCE_RESULTS="$RES" bash scripts/run-once.sh n1 -- bash -c 'exit 3' >/dev/null 2>&1); rc=$?
check "no run id: the command's exit code (3) is still returned" 3 "$rc"
check "no run id: nothing is written" absent "$(present "$RES")"
(cd "$S" && EVIDENCE_RUN_ID='' EVIDENCE_RESULTS="$RES" bash scripts/run-once.sh n2 -- true >/dev/null 2>&1)
check "run id set but EMPTY: nothing is written either" absent "$(present "$RES")"
(cd "$S" && bash scripts/run-once.sh n3 -- true >/dev/null 2>&1)
check "no run id and the default results path: no .evidence directory appears" absent "$(present "$S/.evidence")"
RUN=r1; ro n4 -- true >/dev/null 2>&1
check "control: with a run id the same call writes" present "$(present "$RES")"
check "no run id: resolve says miss no-run-id even though a good line exists" "miss no-run-id" "$(cd "$S" && env -u EVIDENCE_RUN_ID EVIDENCE_RESULTS="$RES" bash scripts/run-once.sh resolve n4 true | cut -f1,2 | tr '\t' ' ')"
check "no run id: counts offers nothing" 0 "$(cd "$S" && env -u EVIDENCE_RUN_ID EVIDENCE_RESULTS="$RES" bash scripts/run-once.sh counts | wc -l | tr -d ' ')"
(cd "$S" && EVIDENCE_RUN_ID='a b' EVIDENCE_RESULTS="$RES" bash scripts/run-once.sh n5 -- true >/dev/null 2>&1); check "a run id outside the charset is refused (2)" 2 "$?"

# ---- attest: the match rules ----------------------------------------------------------------
fresh att
ro a1 -- bash -c 'echo summary-one' >/dev/null 2>&1
CMD='bash -c echo\ summary-one'
check "resolve: same id + command + tree + run -> attested rc 0" "attested 0" "$(res a1 "$CMD")"
check "resolve: the attested line carries the evidence" "summary-one" "$(rr resolve a1 "$CMD" | cut -f7)"
check "resolve: the attested line names its line number" 1 "$(rr resolve a1 "$CMD" | cut -f3)"
check "resolve: another id -> miss" "miss" "$(kind a2 "$CMD")"
check "resolve: command string differs -> miss" "miss" "$(kind a1 "$CMD x")"
RUN=r2; check "resolve: another run id -> miss" "miss" "$(kind a1 "$CMD")"; RUN=r1
check "resolve: too old (max age -1) -> miss" "miss" "$(cd "$S" && EVIDENCE_MAX_AGE=-1 EVIDENCE_RESULTS="$RES" EVIDENCE_RUN_ID=r1 bash scripts/run-once.sh resolve a1 "$CMD" | cut -f1)"
echo changed >> "$S/tracked.txt"
check "resolve: tree went from clean to dirty -> miss" "miss" "$(kind a1 "$CMD")"
ro a3 -- bash -c 'echo dirty-run' >/dev/null 2>&1
check "resolve: a line recorded on the dirty tree is attested on that same dirty tree" "attested" "$(kind a3 'bash -c echo\ dirty-run')"
echo changed-again >> "$S/tracked.txt"
check "resolve: the dirty content changed since -> miss" "miss" "$(kind a3 'bash -c echo\ dirty-run')"
git -C "$S" checkout -q -- tracked.txt
check "resolve: tree back to clean -> the clean line is attested again" "attested" "$(kind a1 "$CMD")"
echo new > "$S/untracked.txt"
check "resolve: an untracked file makes the tree dirty -> miss" "miss" "$(kind a1 "$CMD")"
ro a4 -- bash -c 'echo untracked-run' >/dev/null 2>&1
check "resolve: a line recorded with that untracked file is attested while it is unchanged" "attested" "$(kind a4 'bash -c echo\ untracked-run')"
echo different-content > "$S/untracked.txt"
check "resolve: the CONTENT of an untracked file changed (same path, same status) -> miss" "miss" "$(kind a4 'bash -c echo\ untracked-run')"
rm -f "$S/untracked.txt"
commit "next"
check "resolve: another HEAD -> miss" "miss" "$(kind a1 "$CMD")"
fresh att2
ro a1 -- bash -c 'echo summary-one' >/dev/null 2>&1
mkdir -p "$S/.evidence" "$S/.prod/evidence"; : > "$S/.evidence/x"; : > "$S/.prod/evidence/x.json"
check "resolve: .evidence and .prod/evidence do not dirty the tree" "attested" "$(kind a1 "$CMD")"

# ---- the tree identity ignores user / textconv / external-diff configuration -------------------
printf '*.dat diff=hide\n' > "$S/.gitattributes"; echo a > "$S/t.dat"; git -C "$S" add .gitattributes t.dat; commit "dat"
tid() { (cd "$S" && bash scripts/run-once.sh tree-id); }
git -C "$S" config diff.hide.textconv true
echo b > "$S/t.dat"; i1=$(tid); echo b2 > "$S/t.dat"; i2=$(tid)
check "tree-id: a textconv driver that hides the change does not hide it from the identity" "differ" "$([ "$i1" != "$i2" ] && echo differ || echo same)"
git -C "$S" config --unset diff.hide.textconv
git -C "$S" config diff.external true
echo b3 > "$S/t.dat"; j1=$(tid); echo b4 > "$S/t.dat"; j2=$(tid)
check "tree-id: an external diff program that prints nothing does not hide the change" "differ" "$([ "$j1" != "$j2" ] && echo differ || echo same)"
git -C "$S" config --unset diff.external
git -C "$S" checkout -q -- t.dat

# ---- attest: the file itself is not trustworthy ---------------------------------------------
fresh bad
check "resolve: no results file -> miss no-results-file" "miss no-results-file" "$(res a1 "$CMD")"
: > "$RES"
check "resolve: an empty results file -> miss empty-results-file" "miss empty-results-file" "$(res a1 "$CMD")"
printf '\n\n' > "$RES"
check "resolve: a file of blank lines -> miss empty-results-file" "miss empty-results-file" "$(res a1 "$CMD")"
ro a1 -- bash -c 'echo summary-one' >/dev/null 2>&1
good=$(grep . "$RES")
printf '%s\n' "garbage line" >> "$RES"
check "resolve: a malformed line anywhere voids the WHOLE file" "miss malformed-results-file" "$(res2 a1 "$CMD")"
n=0
for mut in '$1="v2"' '$4="zero"' '$4="00"' '$4="01"' '$4="1000"' '$4="-1"' '$4=""' '$6="nothex"' "\$6=substr(\$6,1,63)" '$9="notatree"' '$9=substr($9,1,40)"+dirty-abc"' '$10=""' '$10="r 1"' '$2="a b"' '$7="yesterday"' '$8="12ab"' '$8="0123456789"' '$8="1"' '$11="x"' '$12=$12 "\r"' '$15="extra"' 'NF=13' '$13="abc"' '$13=""' '$14="abc"' '$14=substr($14,1,15)" "' '$13="ZZZZZZZZZZZZ"'; do
  n=$((n+1)); printf '%s\n' "$good" | awk -F'\t' -v OFS='\t' "{ $mut; print }" > "$RES"
  check "resolve: malformed variant $n ($mut) is never attested" "miss malformed-results-file" "$(res2 a1 "$CMD")"
done
future=$(( $(date +%s) + 100000 ))
printf '%s\n' "$good" | awk -F'\t' -v OFS='\t' -v f="$future" '{ $8=f; print }' > "$RES"
check "resolve: an epoch far in the future (beyond +300 s) is refused, never attested" "miss malformed-results-file" "$(res2 a1 "$CMD")"
near=$(( $(date +%s) + 100 ))
printf '%s\n' "$good" | awk -F'\t' -v OFS='\t' -v f="$near" '{ $8=f; print }' > "$RES"
check "resolve: an epoch a little ahead (within +300 s of skew) is still attested" "attested" "$(kind a1 "$CMD")"
printf '%s\n' "$good" > "$RES"
check "resolve: the unmodified line is attested (the mutations above were real)" "attested" "$(kind a1 "$CMD")"
printf '%s\n' "$good" | awk -F'\t' -v OFS='\t' '{ $4="00"; print }' > "$RES"
check "counts: a hand-written exit field 00 voids the file for counts too" 0 "$(rr counts | wc -l | tr -d ' ')"

# ---- attest: failures and duplicates --------------------------------------------------------
fresh dup
echo 1 > "$S/gates/x.rc"; ro a1 -- bash gates/x.sh >/dev/null 2>&1
check "resolve: a recorded FAILURE is attested as rc 1, never as a pass" "attested 1" "$(res a1 "bash gates/x.sh")"
echo 0 > "$S/gates/x.rc"; ro a1 -- bash gates/x.sh >/dev/null 2>&1
check "resolve: conflicting outcomes for one id -> miss" "miss conflicting-lines-for-this-id" "$(res a1 "bash gates/x.sh")"
fresh dup2
ro a1 -- bash gates/x.sh >/dev/null 2>&1; ro a1 -- bash gates/x.sh >/dev/null 2>&1
check "resolve: a duplicate with the SAME outcome is attested" "attested" "$(kind a1 "bash gates/x.sh")"
check "resolve: ...and names the last line" 2 "$(rr resolve a1 "bash gates/x.sh" | cut -f3)"
ro a1 -- bash gates/y.sh >/dev/null 2>&1
check "resolve: a failing line under ANOTHER command string does not conflict" "attested 0" "$(res a1 "bash gates/x.sh")"

# ---- resolve-set: several wants, one tree measurement ----------------------------------------
fresh set
echo 0 > "$S/gates/x.rc"; ro s1 -- bash gates/x.sh >/dev/null 2>&1; echo 2 > "$S/gates/x.rc"; ro s2 -- bash gates/x.sh >/dev/null 2>&1
set_out=$(printf 's1\tbash gates/x.sh\ns2\tbash gates/x.sh\ns3\tbash gates/x.sh\n' | (cd "$S" && EVIDENCE_RESULTS="$RES" EVIDENCE_RUN_ID=r1 bash scripts/run-once.sh resolve-set | cut -f1-3 | tr '\t' ' ' | tr '\n' '|'))
check "resolve-set: one verdict per want, in order (pass, fail, miss)" "s1 attested 0|s2 attested 2|s3 miss no-line-for-this-id-command-tree-run|" "$set_out"

# ---- the tree changing under the command ----------------------------------------------------
fresh uns
ro u1 -- bash -c 'echo made > unstable-made.txt' >/dev/null 2>&1
check "run: a command that changes the tree is recorded unstable" 1 "$(cut -f9 "$RES" | grep -c '+unstable$')"
check "resolve: an unstable line is never attested" "miss" "$(kind u1 "bash -c echo\ made\ \>\ unstable-made.txt")"
rm -f "$S/unstable-made.txt"

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
check "counts: the count from the single pass equals the count from running the suite" "$direct" "$(rr counts | cut -f3)"
check "counts: the recorded command string is carried for the reader to compare" "bash $T/fake-selftest.sh" "$(rr counts | cut -f2)"
ro --count "selftest:fail-selftest.sh" -- bash -c 'echo "9 ok"; exit 1' >/dev/null 2>&1
check "counts: a FAILING suite's count is not offered" 1 "$(rr counts | wc -l | tr -d ' ')"
cp "$RES" "$T/res-cnt.good"
awk -F'\t' -v OFS='\t' '{$9="0000000000000000000000000000000000000000+clean"; print}' "$T/res-cnt.good" > "$RES"
check "counts: a line with a tampered tree identity (well-formed, other HEAD) is not trusted" 0 "$(rr counts | wc -l | tr -d ' ')"
cp "$T/res-cnt.good" "$RES"; RUN=r9
check "counts: a line from another run is not trusted" 0 "$(rr counts | wc -l | tr -d ' ')"; RUN=r1
check "counts: the untampered file offers the suite (the cases above were real)" 1 "$(rr counts | grep -c 'fake-selftest.sh')"
fresh cnt2
echo 17 > "$S/gates/cnt.n"; ro --quiet --count s1 -- bash gates/cnt.sh >/dev/null 2>&1; ro --quiet --count s1 -- bash gates/cnt.sh >/dev/null 2>&1
check "counts: the same count twice is offered once" 1 "$(rr counts | wc -l | tr -d ' ')"
echo 18 > "$S/gates/cnt.n"; ro --quiet --count s1 -- bash gates/cnt.sh >/dev/null 2>&1
check "counts: two different counts for one suite and command -> not offered" 0 "$(rr counts | wc -l | tr -d ' ')"
printf 'garbage\n' >> "$RES"
check "counts: a malformed file offers nothing" 0 "$(rr counts | wc -l | tr -d ' ')"

# ---- THE CLEAN ENVIRONMENT: nothing a caller or a Makefile exported reaches the command ---------
# provenance: candidate; ttl: 2027-02-27; pinning: true
# dump.sh writes the environment it sees, how `grep` resolves, what a glob gives and its shell options.
printf '#!/usr/bin/env bash\n{ env | sort; echo "TYPE_GREP=$(type -t grep)"; echo "GLOB=$(echo gates/*.sh)"; echo "SET=$-"; } > "$1"\n' > "$S/gates/dump.sh"
fresh env; D="$T/out/dump"
dump() { rm -f "$D"; (cd "$S" && env "$@" bash scripts/run-once.sh d -- bash gates/dump.sh "$D" >/dev/null 2>&1); }
seen() { grep -c "^$1=" "$D" 2>/dev/null | tr -d ' '; }
dump SKIP=1;                         check "env: an exported SKIP=1 does not reach the command" 0 "$(seen SKIP)"
printf 'export SKIP_FROM_BE=1\n' > "$T/be.sh"
dump BASH_ENV="$T/be.sh";            check "env: BASH_ENV is neither passed nor sourced by the command's shell" "0 0" "$(seen BASH_ENV) $(seen SKIP_FROM_BE)"
dump ENV="$T/be.sh";                 check "env: ENV does not reach the command" 0 "$(seen ENV)"
(cd "$S" && rm -f "$D" && bash -c 'grep() { echo hijack; }; export -f grep; bash scripts/run-once.sh d -- bash gates/dump.sh "$0"' "$D" >/dev/null 2>&1)
check "env: an exported bash function named like a command the gate calls does not reach it" "TYPE_GREP=file" "$(grep '^TYPE_GREP=' "$D")"
dump 'GLOBIGNORE=*';                 check "env: GLOBIGNORE is dropped and the glob still expands" "0 1" "$(seen GLOBIGNORE) $(grep -c 'gates/x.sh' "$D")"
dump IFS=x;                          check "env: an exported IFS does not reach the command" 0 "$(seen IFS)"
dump CDPATH=/tmp;                    check "env: CDPATH does not reach the command" 0 "$(seen CDPATH)"
dump SHELLOPTS=xtrace BASHOPTS=nullglob; check "env: SHELLOPTS / BASHOPTS are dropped (no xtrace in the command's shell)" "0 0 0" "$(seen SHELLOPTS) $(seen BASHOPTS) $(grep -c '^SET=.*x' "$D")"
dump MAKEFLAGS=w MAKELEVEL=1 MFLAGS=-w; check "env: MAKEFLAGS / MAKELEVEL / MFLAGS do not reach the command" 0 "$(( $(seen MAKEFLAGS) + $(seen MAKELEVEL) + $(seen MFLAGS) ))"
dump PATH=".:$PATH";                 check "env: PATH is TRUSTED and passed as is (a relative . first stays first; documented boundary)" 1 "$(grep -c '^PATH=\.:' "$D")"
dump GIT_DIR=/nonexistent GIT_INDEX_FILE=/nonexistent; check "env: GIT_* variables do not reach the command" 0 "$(( $(seen GIT_DIR) + $(seen GIT_INDEX_FILE) ))"
dump CLAUDE_CONFIG_DIR=/cfg GOROOT=/g GOPATH=/gp pythonLocation=/p RUNNER_TEMP=/r LANG=C GOFLAGS=-mod=mod GONOSUMDB=x SHELLCHECK_OPTS=-e1 REGISTRIES_DIR=/x DB_PIN_TODAY=2000-01-01
check "env: allowlisted names DO reach the command (non-vacuity of the pass-through)" "/cfg /g /gp /p /r C" "$(for v in CLAUDE_CONFIG_DIR GOROOT GOPATH pythonLocation RUNNER_TEMP LANG; do sed -n "s/^$v=//p" "$D"; done | tr '\n' ' ' | sed 's/ $//')"
check "env: ...and GOFLAGS, GONOSUMDB, SHELLCHECK_OPTS, REGISTRIES_DIR, DB_PIN_TODAY do not" 0 "$(( $(seen GOFLAGS) + $(seen GONOSUMDB) + $(seen SHELLCHECK_OPTS) + $(seen REGISTRIES_DIR) + $(seen DB_PIN_TODAY) ))"
# a target-specific export and make's own command-line variables, through a REAL make
MM="$T/mkenv"; mkdir -p "$MM/scripts" "$MM/gates"; cp "$root/scripts/run-once.sh" "$MM/scripts/"; cp "$S/gates/dump.sh" "$MM/gates/"
printf '.PHONY: x\nx: export SKIP := 1\nx: export BASH_ENV := %s\nx:\n\t@bash scripts/run-once.sh d -- bash gates/dump.sh %s\n' "$T/be.sh" "$D" > "$MM/Makefile"
git -C "$MM" init -q . && git -C "$MM" add -A && git -C "$MM" -c user.email=t@t -c user.name=t commit -q -m base
rm -f "$D"; (cd "$MM" && make --no-print-directory x FOO=bar >/dev/null 2>&1)
check "env: through a real make, a target-specific export / BASH_ENV / MAKEFLAGS / MAKELEVEL never reach the command" "present 0 0 0 0 0" "$(present "$D") $(seen SKIP) $(seen BASH_ENV) $(seen SKIP_FROM_BE) $(seen MAKEFLAGS) $(seen MAKELEVEL)"
# a weakening variable against the REAL gate it weakens (check-registries.sh reads REGISTRIES_DIR)
RG="$T/regrepo"; mkdir -p "$RG/_shared/probes" "$RG/registries" "$T/cleanreg"
cp "$root/_shared/probes/check-registries.sh" "$RG/_shared/probes/"
printf 'entries:\n  - id: w1\n    obligation: o\n    owner: t\n    created: 2020-01-01\n    expires: 2020-02-01\n    reason: expired long ago\n' > "$RG/registries/waivers.yaml"
printf 'entries:\n  - id: ok1\n    obligation: o\n    owner: t\n    created: 2020-01-01\n    expires: never\n    reason: permanent lever\n' > "$T/cleanreg/waivers.yaml"
git -C "$RG" init -q . && git -C "$RG" add -A && git -C "$RG" -c user.email=t@t -c user.name=t commit -q -m base
(cd "$RG" && bash _shared/probes/check-registries.sh >/dev/null 2>&1); r_plain=$?
(cd "$RG" && REGISTRIES_DIR="$T/cleanreg" bash _shared/probes/check-registries.sh >/dev/null 2>&1); r_weak=$?
cp "$root/scripts/run-once.sh" "$RG/scripts-run-once.sh" 2>/dev/null; mkdir -p "$RG/scripts"; mv "$RG/scripts-run-once.sh" "$RG/scripts/run-once.sh"
(cd "$RG" && REGISTRIES_DIR="$T/cleanreg" bash scripts/run-once.sh reg -- bash _shared/probes/check-registries.sh >/dev/null 2>&1); r_run=$?
check "env: control, the real gate fails on an expired waiver (1) and the variable WOULD weaken it (0)" "1 0" "$r_plain $r_weak"
check "env: REGISTRIES_DIR set by the caller does not reach the real gate run through the runner (still 1)" 1 "$r_run"
# the clean START of the runner itself (a direct run): a BASH_ENV, exported functions or aliases leaked by accident must not
# stand in for a command the runner uses, and the gate must still be run under the allowlist
cat > "$T/bf.sh" <<'BF'
export SKIP=1
env() { /usr/bin/env SKIP=1 "$@"; }
unset() { return 0; }
exec() { return 0; }
printf() { return 0; }
git() { return 1; }
BF
printf 'shopt -s expand_aliases\nalias unset=true exec=true env="env SKIP=1" printf=true\nexport SKIP=1\n' > "$T/ba2.sh"
dump BASH_ENV="$T/bf.sh";            check "clean start: BASH_ENV defining functions env/unset/exec/printf/git does not reach the gate (SKIP unseen, env is a file)" "0 file" "$(seen SKIP) $(sed -n 's/^TYPE_GREP=//p' "$D" | sed 's/.*/file/')"
dump BASH_ENV="$T/ba2.sh";           check "clean start: BASH_ENV aliasing unset/exec/env/printf does not reach the gate" 0 "$(seen SKIP)"
dump EVIDENCE_CLEAN_ENV=1 SKIP=1;    check "clean start: the old EVIDENCE_CLEAN_ENV marker is not trusted and not passed" "0 0" "$(seen SKIP) $(seen EVIDENCE_CLEAN_ENV)"
(cd "$S" && rm -f "$D" && bash -c 'env() { /usr/bin/env SKIP=1 "$@"; }; unset() { return 0; }; export -f env unset; bash scripts/run-once.sh d -- bash gates/dump.sh "$0"' "$D" >/dev/null 2>&1)
check "clean start: exported functions env/unset from a bash parent do not reach the gate" 0 "$(seen SKIP)"
dump SHELLOPTS=xtrace 'PS4=$(touch '"$T"'/pwned)'; check "clean start: SHELLOPTS=xtrace with a command substitution in PS4 expands nothing" "absent 0" "$(present "$T/pwned") $(seen SHELLOPTS)"
(cd "$S" && MAKEFLAGS=n bash scripts/run-once.sh d -- true >/dev/null 2>&1); check "clean start: refuses under make -n (2) before the environment is cleaned" 2 "$?"
check "tree-id: a GIT_DIR in the caller's environment cannot redirect the identity" "$(cd "$S" && bash scripts/run-once.sh tree-id)" "$(cd "$S" && GIT_DIR=/nonexistent bash scripts/run-once.sh tree-id)"

# ---- the line states which contract it ran under, and a reader trusts only its own ---------------
fresh sig
ro h1 -- bash -c 'echo hello' >/dev/null 2>&1
want_env=$(printf '%s\n' PATH HOME TMPDIR LANG LC_ALL LC_CTYPE TERM USER LOGNAME CI GITHUB_ACTIONS CLAUDE_CONFIG_DIR EVIDENCE_RUN_ID EVIDENCE_RESULTS GOROOT GOPATH GOCACHE GOMODCACHE GOPROXY GOTOOLCHAIN LD_LIBRARY_PATH pythonLocation PKG_CONFIG_PATH RUNNER_TEMP RUNNER_OS GITHUB_WORKSPACE XDG_CACHE_HOME | git hash-object --stdin | cut -c1-12)
check "line: column 13 is the hash of the allowlist NAMES (never values)" "$want_env" "$(cut -f13 "$RES")"
check "line: column 14 is the hash of the runner script itself" "$(git hash-object "$S/scripts/run-once.sh" | cut -c1-16)" "$(cut -f14 "$RES")"
good=$(cat "$RES")
printf '%s\n' "$good" | awk -F'\t' -v OFS='\t' '{ $13="aaaaaaaaaaaa"; print }' > "$RES"
check "resolve: a well-formed line under ANOTHER allowlist hash is never attested" "miss" "$(kind h1 'bash -c echo\ hello')"
printf '%s\n' "$good" | awk -F'\t' -v OFS='\t' '{ $14="aaaaaaaaaaaaaaaa"; print }' > "$RES"
check "resolve: a well-formed line under ANOTHER runner hash is never attested" "miss" "$(kind h1 'bash -c echo\ hello')"
check "counts: ...nor offered by counts" 0 "$(rr counts | wc -l | tr -d ' ')"
printf '%s\n' "$good" > "$RES"
check "resolve: the unmodified line is attested (control)" "attested" "$(kind h1 'bash -c echo\ hello')"
# editing the runner voids earlier lines even when git cannot see the edit (the file is IGNORED)
RX="$T/rx"; mkdir -p "$RX/scripts"; cp "$root/scripts/run-once.sh" "$RX/scripts/run-once.sh"; echo seed > "$RX/seed.txt"
git -C "$RX" init -q . && printf 'scripts/run-once.sh\n' >> "$RX/.git/info/exclude" && git -C "$RX" add -A && git -C "$RX" -c user.email=t@t -c user.name=t commit -q -m base
rxr() { (cd "$RX" && EVIDENCE_RESULTS="$T/rx.tsv" EVIDENCE_RUN_ID=r1 bash scripts/run-once.sh "$@"); }
rm -f "$T/rx.tsv"; rxr x1 -- true >/dev/null 2>&1
check "runner hash: a line is attested by the runner that wrote it" "attested" "$(rxr resolve x1 true | cut -f1)"
echo '# edited' >> "$RX/scripts/run-once.sh"
check "runner hash: editing the runner (invisible to git here) voids the line" "miss" "$(rxr resolve x1 true | cut -f1)"

# ---- MAKEFLAGS / MFLAGS, read the way make WRITES them (table through the real function) --------
# R = a dry run / question / touch (refuse), A = anything else (run and record)
tbl=$(cd "$S" && source scripts/run-once.sh && while IFS='|' read -r exp mf; do
  if [[ "$mf" == MFLAGS=* ]]; then MAKEFLAGS='' MFLAGS="${mf#MFLAGS=}" make_dry_run && got=R || got=A
  else MAKEFLAGS="$mf" MFLAGS='' make_dry_run && got=R || got=A; fi
  [[ "$got" == "$exp" ]] || echo "WRONG[$exp] <$mf> got $got"
done <<'TABLE'
R|n
R|nw
R|kn
A|w
A|k
A|B
R|-n
A|-Otarget
A|-Iinc
A|-I inc
R|-j4 -n
A|-j4
A|-l2.5
A|--no-print-directory
R| --jobserver-auth=3,4 -n
A|w -- VAR=n
A|e -- VAR=xn
A|-ofile.txt
A|-Wnothing
A|-Cdir
A|-ffile
A|-Edebug
R|--dry-run
R|--just-print
R|--recon
R|--question
R|--touch
A|--debug=n
A|--include-dir=nt
R|MFLAGS=-n
R|q
R|t
R|-q
R|-t
R|-nj4
A|-j4n
R|-ks -t
A| -j4 --jobserver-auth=3,4
TABLE
)
check "MAKEFLAGS table: all 39 spellings decided as make writes them (n nw kn w k B -n -Otarget -Iinc ...)" "" "$tbl"
rm -f "$RES"; MAKEFLAGS='-Otarget' ro dr -- true >/dev/null 2>&1; rc=$?
check "dry run: MAKEFLAGS='-Otarget' is NOT a dry run end to end (no false refusal) -> recorded" "0 present" "$rc $(present "$RES")"

# ---- the trust model is stated in the header -----------------------------------------------------
check "header: the trust model says this is an accident guard, not a tamper guard (run-once.sh)" 1 "$(grep -c 'It is an accident guard, not a tamper guard' "$root/scripts/run-once.sh")"
check "header: ...and no claim of resistance to a hostile Makefile or caller is left" 0 "$(grep -ciE 'whatever Makefile|out of the trust path|same-job tampering|whoever calls this script' "$root/scripts/run-once.sh")"

echo "$((CASES-FAILED)) ok, $FAILED failed"
(( FAILED == 0 ))
