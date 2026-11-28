#!/usr/bin/env bash
# row-catalogue-selftest.sh — proves row-catalogue.sh goes RED when the catalogue
# and the probe disagree, and GREEN when they do not. Hermetic (fixtures in a temp
# dir) except ONE case on the real tree. Sequential, no background work.
#
# Mutation lines at the end drive a scratch COPY of the gate with one check
# removed; the case that guards that check must then fail (printed as RED).
set -uo pipefail

HERE="$(cd "${0%/*}" && pwd)"
GATE="$HERE/row-catalogue.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/rc-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$T"' EXIT
TAB=$'\t'
START=$SECONDS
ok=0; failed=0

pass() { ok=$((ok+1)); echo "ok   $1"; }
fail() { failed=$((failed+1)); echo "FAIL $1"; }

# expect <name> <want-rc> <want-substring-or-empty> <gate> <probe> <rowsdir>
expect() {
  local name="$1" want="$2" sub="$3" gate="$4" probe="$5" rows="$6" out rc
  out="$(bash "$gate" "$probe" "$rows" 2>&1)"; rc=$?
  if [[ "$rc" == "$want" && ( -z "$sub" || "$out" == *"$sub"* ) ]]; then pass "$name"
  else fail "$name (rc=$rc want $want; want substring [$sub]; got: $(printf '%s' "$out" | head -n 3 | tr '\n' '|'))"; fi
}

HDR="id${TAB}dimension${TAB}group${TAB}bucket${TAB}scope${TAB}property${TAB}source"
# line <id> <bucket> <scope> <property> <source>
line() { printf '%s\t1\tstatic\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5"; }

# fresh <name>: a new fixture dir with probe + rows.d, echo its path
fresh() { mkdir -p "$T/$1/rows.d"; echo "$T/$1"; }

BASE_PROBE='#!/usr/bin/env bash
row "alpha" PASS "x"
row "beta" FAIL "y"
'
mkbase() { # <dir> : probe with alpha(2) beta(3), matching catalogue
  printf '%s' "$BASE_PROBE" > "$1/probe.sh"
  { echo "$HDR"; line alpha neutral repo "p one" 2; line beta tool-run unit "p two" 3; } > "$1/rows.d/a.tsv"
}

# 1. real tree, GREEN
expect "real tree: probe and catalogue agree" 0 "row-catalogue: ok" "$GATE" "$HERE/verify-standard.sh" "$HERE/verify-standard.d/rows.d"

# 2. baseline fixture GREEN (so the RED cases below differ by exactly one thing)
d=$(fresh base); mkbase "$d"
expect "fixture baseline is GREEN" 0 "ok --" "$GATE" "$d/probe.sh" "$d/rows.d"

# 3. uncatalogued id
d=$(fresh missing); mkbase "$d"; echo 'row "gamma" PASS "z"' >> "$d/probe.sh"
expect "uncatalogued id -> RED naming it" 1 'MISSING: the probe emits `gamma`' "$GATE" "$d/probe.sh" "$d/rows.d"

# 4. stale line
d=$(fresh stale); mkbase "$d"; line zeta neutral repo "gone" 9 >> "$d/rows.d/a.tsv"
expect "stale catalogue line -> RED naming it" 1 'STALE: `zeta`' "$GATE" "$d/probe.sh" "$d/rows.d"

# 5. duplicate (same file, and across files)
d=$(fresh dup); mkbase "$d"; line alpha neutral repo "again" 2 >> "$d/rows.d/a.tsv"
expect "duplicate id in one file -> RED" 1 'appears twice' "$GATE" "$d/probe.sh" "$d/rows.d"
d=$(fresh dup2); mkbase "$d"; { echo "$HDR"; line alpha neutral repo "again" 2; } > "$d/rows.d/b.tsv"
expect "duplicate id across files -> RED" 1 'appears twice' "$GATE" "$d/probe.sh" "$d/rows.d"

# 6. bad bucket / scope / empty property / columns / dimension / source
d=$(fresh bucket); mkbase "$d"; { echo "$HDR"; line alpha shell repo "p" 2; line beta tool-run unit "p" 3; } > "$d/rows.d/a.tsv"
expect "unknown bucket -> RED" 1 'unknown bucket `shell`' "$GATE" "$d/probe.sh" "$d/rows.d"
d=$(fresh scope); mkbase "$d"; { echo "$HDR"; line alpha neutral galaxy "p" 2; line beta tool-run unit "p" 3; } > "$d/rows.d/a.tsv"
expect "unknown scope -> RED" 1 'unknown scope `galaxy`' "$GATE" "$d/probe.sh" "$d/rows.d"
d=$(fresh prop); mkbase "$d"; { echo "$HDR"; line alpha neutral repo "" 2; line beta tool-run unit "p" 3; } > "$d/rows.d/a.tsv"
expect "empty property -> RED" 1 'empty property' "$GATE" "$d/probe.sh" "$d/rows.d"
d=$(fresh cols); mkbase "$d"; { echo "$HDR"; printf 'alpha\t1\tstatic\tneutral\trepo\tp\n'; line beta tool-run unit "p" 3; } > "$d/rows.d/a.tsv"
expect "wrong column count -> RED" 1 '6 columns, expected 7' "$GATE" "$d/probe.sh" "$d/rows.d"
d=$(fresh dim); mkbase "$d"; { echo "$HDR"; printf 'alpha\tx\tstatic\tneutral\trepo\tp\t2\n'; line beta tool-run unit "p" 3; } > "$d/rows.d/a.tsv"
expect "non-numeric dimension -> RED" 1 'dimension `x`' "$GATE" "$d/probe.sh" "$d/rows.d"
d=$(fresh src); mkbase "$d"; { echo "$HDR"; line alpha neutral repo "p" abc; line beta tool-run unit "p" 3; } > "$d/rows.d/a.tsv"
expect "non-numeric source -> RED" 1 'not a positive line number' "$GATE" "$d/probe.sh" "$d/rows.d"

# 7. source line hint drift is a note, NOT a failure
d=$(fresh drift); mkbase "$d"; { echo "$HDR"; line alpha neutral repo "p" 40; line beta tool-run unit "p" 41; } > "$d/rows.d/a.tsv"
expect "drifted source hints stay GREEN and are counted" 0 '2 source-line hints drifted' "$GATE" "$d/probe.sh" "$d/rows.d"

# 8. dynamic pattern
d=$(fresh dyn); printf '%s\n' 'for k in a b; do row "impl-$k" PASS "x"; done' 'row "impl-literal" PASS "y"' > "$d/probe.sh"
{ echo "$HDR"; line 'impl-*' test-exec unit "pattern" 1; } > "$d/rows.d/a.tsv"
expect "dynamic pattern covers the dynamic row and a matching literal" 0 '1 dynamic' "$GATE" "$d/probe.sh" "$d/rows.d"
d=$(fresh dyn2); printf '%s\n' 'row "impl-$k" PASS "x"' > "$d/probe.sh"
{ echo "$HDR"; line 'other-*' test-exec unit "pattern" 1; } > "$d/rows.d/a.tsv"
expect "dynamic id with no catalogued pattern -> RED" 1 'MISSING: the probe emits `impl-*`' "$GATE" "$d/probe.sh" "$d/rows.d"
d=$(fresh dyn3); printf '%s\n' 'row "plain" PASS "x"' > "$d/probe.sh"
{ echo "$HDR"; line plain neutral repo "p" 1; line 'ghost-*' test-exec unit "pattern" 1; } > "$d/rows.d/a.tsv"
expect "pattern matching nothing -> RED as stale" 1 'STALE: pattern `ghost-*`' "$GATE" "$d/probe.sh" "$d/rows.d"

# 9. comments
d=$(fresh comment); mkbase "$d"; printf '%s\n' '# row "ghost" PASS "only in a comment"' '   # row "ghost2" PASS "indented comment"' >> "$d/probe.sh"
expect "id only in a full-line comment is not emitted" 0 'ok --' "$GATE" "$d/probe.sh" "$d/rows.d"
d=$(fresh comment2); mkbase "$d"; printf '%s\n' '# row "ghost" PASS "only in a comment"' >> "$d/probe.sh"; line ghost neutral repo "p" 4 >> "$d/rows.d/a.tsv"
expect "catalogued id that exists only in a comment -> RED stale" 1 'STALE: `ghost`' "$GATE" "$d/probe.sh" "$d/rows.d"

# 10. strings/heredocs: the rule is textual. Prose without a quoted id is not counted;
#     a row "x" inside a heredoc IS counted (documented limit, pinned here).
d=$(fresh prose); mkbase "$d"; printf '%s\n' 'echo "each row is checked; the row id is quoted elsewhere"' 'echo "a narrow band"' >> "$d/probe.sh"
expect "prose mentioning row is not an id" 0 'ok --' "$GATE" "$d/probe.sh" "$d/rows.d"
d=$(fresh heredoc); mkbase "$d"; printf '%s\n' 'cat <<EOF' 'row "in-heredoc" PASS "text"' 'EOF' >> "$d/probe.sh"
expect "LIMIT: a row call inside a heredoc is counted (text rule)" 1 'MISSING: the probe emits `in-heredoc`' "$GATE" "$d/probe.sh" "$d/rows.d"

# 11. declared (@shard-rows) and ROWS+= registrations
d=$(fresh decl); mkbase "$d"; printf '%s\n' '# @shard-rows dynamic declared-one declared-two' 'ROWS+=("registered|FAIL|boom")' >> "$d/probe.sh"
{ cat "$d/rows.d/a.tsv"; line declared-one neutral repo p 4; line declared-two neutral repo p 4; line registered neutral repo p 5; } > "$d/rows.d/b.tmp"; { echo "$HDR"; tail -n +2 "$d/rows.d/b.tmp"; } > "$d/rows.d/a.tsv"; rm "$d/rows.d/b.tmp"
expect "@shard-rows ids and ROWS+= ids are extracted" 0 '5 ids extracted' "$GATE" "$d/probe.sh" "$d/rows.d"

# 12. nothing checked
d=$(fresh zero); printf '%s\n' '#!/usr/bin/env bash' 'echo nothing here' > "$d/probe.sh"; { echo "$HDR"; line alpha neutral repo p 1; } > "$d/rows.d/a.tsv"
expect "zero ids extracted -> exit 2" 2 'ZERO row ids' "$GATE" "$d/probe.sh" "$d/rows.d"
d=$(fresh zerocat); printf '%s' "$BASE_PROBE" > "$d/probe.sh"; echo "$HDR" > "$d/rows.d/a.tsv"
expect "zero catalogue lines -> exit 2" 2 'ZERO lines' "$GATE" "$d/probe.sh" "$d/rows.d"
d=$(fresh nofile); printf '%s' "$BASE_PROBE" > "$d/probe.sh"
expect "no *.tsv at all -> exit 2" 2 'nothing checked' "$GATE" "$d/probe.sh" "$d/rows.d"

# 13. process-count bound: wrappers on PATH count every exec of the common tools
REALPATH="$PATH"
mkdir -p "$T/bin"
for tool in awk sed grep sort cut tr cat basename dirname find wc head tail sh; do
  real="$(command -v "$tool" 2>/dev/null || true)"; [[ -n "$real" ]] || continue
  printf '#!/bin/sh\necho %s >> "%s"\nexec "%s" "$@"\n' "$tool" "$T/count.log" "$real" > "$T/bin/$tool"
  chmod +x "$T/bin/$tool"
done
count_for() { # <rows> -> number of tool execs while the gate checks a fixture of that size
  local n="$1" dd i
  dd=$(fresh "size$n")
  { echo '#!/usr/bin/env bash'; i=1; while [[ $i -le $n ]]; do echo "row \"id$i\" PASS \"x\""; i=$((i+1)); done; } > "$dd/probe.sh"
  { echo "$HDR"; i=1; while [[ $i -le $n ]]; do line "id$i" neutral repo "p" "$((i+1))"; i=$((i+1)); done; } > "$dd/rows.d/a.tsv"
  : > "$T/count.log"
  PATH="$T/bin:$REALPATH" bash "$GATE" "$dd/probe.sh" "$dd/rows.d" >/dev/null 2>&1
  local rc=$?
  PATH="$REALPATH"
  [[ $rc == 0 ]] || { echo "rc$rc"; return; }
  wc -l < "$T/count.log" | tr -d ' '
}
c50=$(count_for 50); c2000=$(count_for 2000)
if [[ "$c50" == "$c2000" && "$c50" =~ ^[0-9]+$ && "$c50" -le 2 ]]; then pass "process count is constant ($c50) for 50 and 2000 rows"
else fail "process count differs or too high: 50 rows -> $c50, 2000 rows -> $c2000"; fi

# 13b. wiring on the REAL repo files: the gate must be run by `make gates` AND be
# listed in the evidence recorder's GATES, or CI breaks (uncovered) / the gate is orphaned.
ROOT="$(cd "$HERE/../.." && pwd)"
# The Makefile no longer lists gates: `make gates` is one line calling scripts/evidence-record.sh --run gates,
# which runs the `main` group of GATES. So "make gates runs row-catalogue" is now "GATES lists it AND it is
# in the main group", i.e. not in PRE_IDS / POST_IDS / AGG_IDS (those are run at other times).
er_lists_gate() { local t; t=$(sed -n '/^GATES=(/,/^)/p' "$1" | grep -vE '^[[:space:]]*#'); grep -qE '"row-catalogue\|bash [^"]*row-catalogue\.sh"' <<<"$t"; }
er_main_gate() { local g; g=$(grep -E '^(PRE_IDS|POST_IDS|AGG_IDS)=\(' "$1"); er_lists_gate "$1" && [[ "$g" != *row-catalogue* ]]; }
mk_calls_runner() { local t; t=$(sed -n '/^gates:/,/^$/p' "$1" | grep -vE '^[[:space:]]*#'); grep -qE 'evidence-record\.sh --run gates' <<<"$t"; }
if mk_calls_runner "$ROOT/Makefile"; then pass "wiring: Makefile gates: recipe calls the runner (--run gates)"
else fail "wiring: Makefile gates: recipe does not call evidence-record.sh --run gates"; fi
if er_lists_gate "$ROOT/scripts/evidence-record.sh"; then pass "wiring: evidence-record.sh GATES lists row-catalogue"
else fail "wiring: evidence-record.sh GATES does not list row-catalogue"; fi
if er_main_gate "$ROOT/scripts/evidence-record.sh"; then pass "wiring: row-catalogue is in the main group, the one --run gates executes"
else fail "wiring: row-catalogue is not in the main group of GATES"; fi
# mutations on scratch copies: each removal must flip its check RED
grep -v 'evidence-record' "$ROOT/Makefile" > "$T/Makefile.mut"
grep -v 'row-catalogue' "$ROOT/scripts/evidence-record.sh" > "$T/er.mut"
sed 's/^POST_IDS=(/POST_IDS=(row-catalogue /' "$ROOT/scripts/evidence-record.sh" > "$T/er.post"
if mk_calls_runner "$T/Makefile.mut"; then fail "mutation wiring-makefile: NOT caught"; else ok=$((ok+1)); echo "ok   mutation wiring-makefile: RED (Makefile copy that does not call the runner is refused)"; fi
if er_lists_gate "$T/er.mut"; then fail "mutation wiring-gates-array: NOT caught"; else ok=$((ok+1)); echo "ok   mutation wiring-gates-array: RED (GATES copy without the entry is refused)"; fi
if er_main_gate "$T/er.post"; then fail "mutation wiring-group: NOT caught"; else ok=$((ok+1)); echo "ok   mutation wiring-group: RED (row-catalogue moved out of the main group is refused)"; fi

# 14. mutations: a scratch copy of the gate with ONE check removed must be caught
mutant() { # <name> <sed-expr> <case-dir-prepared-by-caller> <want-rc-of-original> <substring>
  local name="$1" expr="$2" dir="$3" want="$4" sub="$5" m="$T/mut-$1.sh" out rc
  sed "$expr" "$GATE" > "$m"
  if cmp -s "$m" "$GATE"; then fail "mutation $name: sed did not change the gate (ERROR)"; return; fi
  out="$(bash "$m" "$dir/probe.sh" "$dir/rows.d" 2>&1)"; rc=$?
  if [[ "$rc" == "$want" && "$out" == *"$sub"* ]]; then fail "mutation $name: NOT caught (mutant still behaves like the gate: rc=$rc)"
  else ok=$((ok+1)); echo "ok   mutation $name: RED (mutant gave rc=$rc; the real gate gives rc=$want with [$sub])"; fi
}
NOP='s/function bad(m) {/function nop(m) {} function bad(m) {/'
mutant missing-id-check "s/if (!hit) bad(/if (!hit) nop(/;$NOP" "$T/missing" 1 'MISSING'
mutant stale-check "s/bad(\"STALE/nop(\"STALE/g;$NOP" "$T/stale" 1 'STALE'
mutant duplicate-check "s/if (id in cline) bad(/if (0) bad(/" "$T/dup" 1 'appears twice'
mutant bucket-validation "s/if (f\[4\] !~ [^)]*)\$\/) bad(/if (0) bad(/" "$T/bucket" 1 'unknown bucket'
mutant comment-filtering 's/if (\$0 ~ \/^\[ \\t\]\*#\/) next$/if (0) next/' "$T/comment" 0 'ok --'

echo "$ok ok, $failed failed ($((SECONDS-START)) s)"
[[ $failed -eq 0 ]]
