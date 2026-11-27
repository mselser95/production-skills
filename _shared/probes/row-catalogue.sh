#!/usr/bin/env bash
# row-catalogue.sh — every row id verify-standard.sh can emit is CATALOGUED, and
# every catalogue line is still emitted.
#
# WHY. verify-standard.sh is one Go-only monolith. Language adapters (Rust,
# Python, TS) can only be built against a list of WHAT each row verifies, how
# language-bound it is (bucket) and whether it is per-repo or per-unit (scope).
# That list is rows.d/*.tsv. A list that nobody checks decays at the first new
# row, so this gate ties it to the probe mechanically, both directions.
#
# Usage: row-catalogue.sh [verify-standard.sh] [rows.d]
# Exit:  0 catalogue and probe agree · 1 they disagree · 2 nothing was checked
#
# THE EXTRACTION RULE (the same one verify-standard.sh's own shard_owners uses,
# so the two cannot disagree about what "a row id" is):
#   * a full-line comment (`^\s*#`) is skipped, EXCEPT `# @shard-rows <group>
#     <id>...`, which DECLARES ids the code builds from variables;
#   * on every other line, each `row "<id>"` where <id> starts with a letter and
#     holds no `"` and no `$` is a LITERAL id (this also matches
#     `implemented_row "<id>"`, as intended); each `ROWS+=("<id>|` is a literal id
#     registered directly;
#   * a quoted id that starts with a letter and CONTAINS `$var`/`${var}` is a
#     DYNAMIC pattern: every variable becomes `*` (`impl-$k` -> `impl-*`).
#     An id that is ONLY a variable (`row "$label"`) is not extractable and is
#     not a pattern; the probe enumerates those through @shard-rows.
# WHAT IT CANNOT SEE: it is a text rule, not a parser. A `row "x"` inside a
# heredoc, a python block or a quoted string IS counted; a trailing `# ... row
# "x"` comment after code IS counted; an id assembled at runtime and declared
# nowhere is invisible (the probe's own not-probed guard catches that at run time).
#
# CATALOGUE FORMAT (tab-separated, first line of each file is the header):
#   id dimension group bucket scope property source
#   dimension: integer or `-`   bucket: neutral|tool-run|test-exec|source-grep
#   scope: repo|unit|?          source: line in the probe where the id appears
#   An id containing `*` is a DYNAMIC pattern; it covers every extracted id it
#   matches and must match at least one thing the probe emits.
#
# SOURCE LINE POLICY: the number is a HINT, not a key. Failing on it would turn
# every unrelated edit to a 6,000-line file red. The gate re-resolves the id by
# the extraction map; a wrong hint is only counted in the summary ("hints
# drifted") and the id itself must still be emitted, else it is STALE (red). The
# number must still be a positive integer.
#
# COST: one process (awk) over the probe and the catalogue, no per-row forks.
set -uo pipefail

PROBE="${1:-${0%/*}/verify-standard.sh}"
ROWS="${2:-${0%/*}/verify-standard.d/rows.d}"

[[ -f "$PROBE" ]] || { echo "row-catalogue: probe not found: $PROBE" >&2; exit 2; }
[[ -d "$ROWS" ]] || { echo "row-catalogue: catalogue dir not found: $ROWS" >&2; exit 2; }
set -- "$ROWS"/*.tsv
[[ -e "$1" ]] || { echo "row-catalogue: no *.tsv in $ROWS -- nothing checked" >&2; exit 2; }

exec awk -v probe="$PROBE" '
function esc(s,   i, c, o) {
  o = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (index("\\.[](){}+?^$|", c)) o = o "\\"
    o = o c
  }
  return o
}
function globre(p,   o, i, c, parts, n) {
  o = ""
  for (i = 1; i <= length(p); i++) {
    c = substr(p, i, 1)
    if (c == "*") o = o ".*"
    else o = o esc(c)
  }
  return "^" o "$"
}
function bad(m) { print "row-catalogue: " m; nbad++ }
function addid(id, ln, kind) {
  if (id in eline) return
  eline[id] = ln; ekind[id] = kind; eord[++ne] = id
  if (kind == "dyn") ndyn++; else nlit++
}
FILENAME == probe {
  if ($0 ~ /^# @shard-rows /) { for (i = 4; i <= NF; i++) addid($i, FNR, "lit"); next }
  if ($0 ~ /^[ \t]*#/) next
  rest = $0
  while (match(rest, /row "[a-zA-Z][^"]*"/)) {
    id = substr(rest, RSTART + 5, RLENGTH - 6)
    if (index(id, "$") == 0) addid(id, FNR, "lit")
    else {
      gsub(/\$\{[^}]*\}|\$[A-Za-z_][A-Za-z0-9_]*/, "*", id)
      addid(id, FNR, "dyn")
    }
    rest = substr(rest, RSTART + RLENGTH)
  }
  rest = $0
  while (match(rest, /ROWS\+=\("[a-zA-Z][^"$|]*\|/)) {
    addid(substr(rest, RSTART + 8, RLENGTH - 9), FNR, "lit")
    rest = substr(rest, RSTART + RLENGTH)
  }
  next
}
{
  if (FNR == 1) { if ($0 !~ /^id\t/) bad(FILENAME ": line 1 is not the header (expected it to start with `id<TAB>`)"); next }
  if ($0 ~ /^[ \t]*$/) next
  ncat++
  n = split($0, f, "\t")
  where = FILENAME ":" FNR
  if (n != 7) { bad(where ": " n " columns, expected 7 (id dimension group bucket scope property source)"); next }
  id = f[1]
  if (id == "") { bad(where ": empty id"); next }
  if (id in cline) bad(where ": id `" id "` appears twice (first at " cwhere[id] ")")
  else { cline[id] = f[7]; cwhere[id] = where; cord[++nc] = id }
  if (f[2] !~ /^([0-9]+|-)$/) bad(where ": `" id "` dimension `" f[2] "` is neither an integer nor `-`")
  if (f[4] !~ /^(neutral|tool-run|test-exec|source-grep)$/) bad(where ": `" id "` unknown bucket `" f[4] "`")
  else nb[f[4]]++
  if (f[5] !~ /^(repo|unit|\?)$/) bad(where ": `" id "` unknown scope `" f[5] "`")
  if (f[6] ~ /^[ ]*$/) bad(where ": `" id "` has an empty property")
  if (f[7] !~ /^[1-9][0-9]*$/) bad(where ": `" id "` source `" f[7] "` is not a positive line number")
  if (index(id, "*")) { npat++; pat[npat] = id; pre[npat] = globre(id) }
}
END {
  if (ne == 0) { print "row-catalogue: the probe " probe " yields ZERO row ids -- nothing was checked (extraction rule drifted, or wrong file?)"; exit 2 }
  if (ncat == 0) { print "row-catalogue: the catalogue has ZERO lines -- nothing was checked"; exit 2 }
  # (a) emitted but not catalogued
  for (i = 1; i <= ne; i++) {
    id = eord[i]
    if (id in cline) continue
    hit = 0
    if (ekind[id] == "lit") for (p = 1; p <= npat; p++) if (id ~ pre[p]) { hit = 1; pcov[pat[p]]++; break }
    if (!hit) bad("MISSING: the probe emits `" id "` (line " eline[id] ") but no catalogue line has it")
  }
  # (b) catalogued but not emitted; (d) source-line hint drift
  for (i = 1; i <= nc; i++) {
    id = cord[i]
    if (index(id, "*")) {
      if (id in eline) continue
      if (id in pcov) continue
      bad("STALE: pattern `" id "` (" cwhere[id] ") matches nothing the probe emits")
      continue
    }
    if (!(id in eline) || ekind[id] != "lit") { bad("STALE: `" id "` (" cwhere[id] ") is catalogued but the probe no longer emits it"); continue }
    if (eline[id] != cline[id] + 0) drift++
  }
  s = sprintf("%d ids extracted (%d literal, %d dynamic), %d catalogued (%d patterns), %d source-line hints drifted", ne, nlit, ndyn, nc, npat, drift)
  if (nbad) { printf "row-catalogue: FAIL %d problem(s) -- %s\n", nbad, s; exit 1 }
  printf "row-catalogue: ok -- %s\n", s
  exit 0
}
' "$PROBE" "$@"
