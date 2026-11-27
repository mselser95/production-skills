#!/usr/bin/env bash
# brand-strings.sh — a generated tree leaves NO trace of any real brand.
#
# WHY THIS EXISTS. A design system and a frontend are generated from a reference
# implementation. The reference belongs to a real company; the generated tree
# must be neutral. A brand survives in places review never reads: a code
# comment, an SVG <title>, a JSON fixture, a lockfile, a directory name. This
# scans a tree for every entry of a denylist so a leaked name goes red.
#
# The denylist is per-user and NOT committed (the real list names the brands the
# repo must never contain): --denylist <file>, else $BRAND_DENYLIST, else the
# gate refuses (exit 2). It also refuses a list with zero effective entries --
# an empty list "passes" everything, and a gate that cannot fail is not a gate.
#
# Matching: case-insensitive SUBSTRING, by design -- a brand inside an
# identifier (`acmecorpButton`) must be caught, so there is no word-boundary
# logic. The price is that a short generic entry produces false positives,
# which is why an entry under 3 characters is refused (it would match nearly
# everything). Case folding is ASCII only (LC_ALL=C, so a text file with odd
# bytes is still text rather than silently "binary").
#
# Scanned: file CONTENTS (every text file: .svg .json .css .ts .tsx .md,
# lockfiles, dotfiles) and PATH components (file and directory names). Binary
# files (what `grep -I` calls binary) are checked by PATH only and COUNTED in
# the summary ("K binary skipped") so a skipped file is visible. Never entered:
# `.git/`, `node_modules/`, and -- when the tree is a git repo -- anything
# git-ignored (git's own view of the tree, tracked + untracked-not-ignored).
#
# COST: a constant number of processes whatever the tree size -- one grep (or
# git grep) pass for contents, one awk pass over the path list. No per-file and
# no per-line forks (the selftest proves the count is equal at 20 and 2000 files).
#
# Cannot see: brands in non-ASCII spelling or with a separator inserted
# (`acme-corp` vs `acmecorp`: list both), brands inside binary content (images,
# fonts) or inside a git-ignored / node_modules file, a tracked file deleted
# from the work tree (its name is still listed), a brand rendered from parts.
#
# Usage: brand-strings.sh <tree> [--denylist <file>]
# Output: `path:line: <entry>` / `path: <entry> (in path)`, sorted, then a summary.
# Exit:  0 clean · 1 findings · 2 nothing checked (no/empty/bad list, empty tree)
set -uo pipefail
export LC_ALL=C

die2() { printf 'brand-strings: refusing -- %s\n' "$1" >&2; exit 2; }

tree="" list="${BRAND_DENYLIST:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --denylist) [[ $# -ge 2 ]] || die2 "--denylist needs a file"; list="$2"; shift 2 ;;
    -*) die2 "unknown option $1" ;;
    *) [[ -z "$tree" ]] || die2 "one tree only"; tree="$1"; shift ;;
  esac
done
[[ -n "$tree" && -d "$tree" ]] || die2 "usage: brand-strings.sh <tree> [--denylist <file>]; '$tree' is not a directory"
[[ -n "$list" ]] || die2 "no denylist (--denylist <file> or \$BRAND_DENYLIST): refusing to report clean against an empty denylist"
[[ -f "$list" && -r "$list" ]] || die2 "denylist '$list' is missing or unreadable: refusing to report clean against an empty denylist"

work="$(mktemp -d "${TMPDIR:-/tmp}/brand-strings.XXXXXX")" || die2 "cannot create a temp dir"
trap 'rm -rf "$work"' EXIT
clean="$work/list"

# normalise: strip CR and edge blanks, drop comments/blanks, lowercase; flag short entries
if ! awk '
  { sub(/\r$/, ""); gsub(/^[ \t]+|[ \t]+$/, "") }
  $0 == "" || substr($0, 1, 1) == "#" { next }
  length($0) < 3 { print "entry shorter than 3 characters: " $0 > "/dev/stderr"; bad = 1; next }
  { print tolower($0) }
  END { exit bad }
' "$list" >"$clean" 2>"$work/err"; then
  die2 "$(cat "$work/err") (it would match everything)"
fi
entries=$(wc -l <"$clean"); entries=$((entries + 0))
[[ $entries -gt 0 ]] || die2 "denylist '$list' has no effective entries: refusing to report clean against an empty denylist"

tree="$(cd "$tree" && pwd)"
cd "$tree" || die2 "cannot enter $tree"

# one listing of files, one contents pass, one binary count: the same trio in either mode
nm=':(exclude,glob)**/node_modules/**'
if [[ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" == true ]]; then
  files=$(git -c core.quotepath=false ls-files -co --exclude-standard -- . "$nm")
  hits=$(git -c core.quotepath=false grep -Iino -F -f "$clean" --untracked --exclude-standard -- . "$nm" 2>"$work/gerr"); grc=$?
  text=$(git -c core.quotepath=false grep -Il -e '' --untracked --exclude-standard -- . "$nm" 2>>"$work/gerr")
  anyl=$(git -c core.quotepath=false grep -l -e '' --untracked --exclude-standard -- . "$nm" 2>>"$work/gerr")
else
  files=$(find . \( -name .git -o -name node_modules \) -prune -o -type f -print | sed 's|^\./||')
  hits=$(grep -rIino -F -f "$clean" --exclude-dir=.git --exclude-dir=node_modules . 2>"$work/gerr" | sed 's|^\./||'); grc=${PIPESTATUS[0]}
  text=$(grep -rIl -e '' --exclude-dir=.git --exclude-dir=node_modules . 2>>"$work/gerr")
  anyl=$(grep -rl -e '' --exclude-dir=.git --exclude-dir=node_modules . 2>>"$work/gerr")
fi
[[ $grc -le 1 ]] || die2 "the content scan itself failed (rc=$grc): $(head -c 300 "$work/gerr")"
[[ -n "$files" ]] || die2 "no files in '$tree': nothing was checked"

nfiles=$(printf '%s\n' "$files" | wc -l); nfiles=$((nfiles + 0))
ntext=0; nany=0
[[ -z "$text" ]] || { ntext=$(printf '%s\n' "$text" | wc -l); ntext=$((ntext + 0)); }
[[ -z "$anyl" ]] || { nany=$(printf '%s\n' "$anyl" | wc -l); nany=$((nany + 0)); }
nbin=$((nany - ntext))   # files with lines that `grep -I` will not read

# findings: content hits are `path:line:matched-text` (lowercased text == the entry);
# path hits come from one awk pass over the file list
{
  [[ -z "$hits" ]] || printf '%s\n' "$hits" | awk '
    { if (match($0, /:[0-9]+:/)) printf "%s:%s: %s\n", substr($0, 1, RSTART - 1), substr($0, RSTART + 1, RLENGTH - 2), tolower(substr($0, RSTART + RLENGTH)) }'
  printf '%s\n' "$files" | awk '
    NR == FNR { e[++n] = $0; next }
    { p = tolower($0); for (i = 1; i <= n; i++) if (index(p, e[i])) print $0 ": " e[i] " (in path)" }
  ' "$clean" -
} | sort -u >"$work/findings"

nf=$(wc -l <"$work/findings"); nf=$((nf + 0))
cat "$work/findings"
if [[ $nf -gt 0 ]]; then
  printf 'brand-strings: FAIL -- %d finding(s), %d file(s), %d entries, %d binary skipped\n' "$nf" "$nfiles" "$entries" "$nbin"
  exit 1
fi
printf 'brand-strings: ok -- %d file(s), %d entries, %d binary skipped\n' "$nfiles" "$entries" "$nbin"
