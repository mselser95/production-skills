#!/usr/bin/env bash
# changed-line coverage: a NON-BLOCKING PR signal.
#
# Every tier's SIGNAL is coverage (see scripts/coverage.sh), but that
# number is a whole-repo average: a PR can add a large, well-covered file
# and hide a small, completely uncovered one inside the same average. This
# script instead restricts coverage to just the lines the PR itself
# changed, by intersecting the diff against a base ref with the existing
# coverage.out profile scripts/coverage.sh already produces.
#
# This is a SIGNAL, never a gate: unlike coverage.sh (which exits 1 below
# its threshold), this script ALWAYS exits 0, no matter what it measures or
# what goes wrong computing it. Any failure degrades to printing the metric
# as unavailable rather than failing the calling job.
set -u

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 0

base_ref="${CHANGED_LINE_COVERAGE_BASE:-origin/main}"
coverage_out="${COVERAGE_OUT:-coverage.out}"

print_and_exit() {
  local pct="$1" covered="$2" total="$3"
  echo "changed-line coverage: ${pct}% (${covered}/${total} lines)"
  exit 0
}

if ! git rev-parse --verify "${base_ref}" >/dev/null 2>&1; then
  echo "changed-line coverage: base ref '${base_ref}' not found (no fetch in this environment, or this is the first commit) -- reporting 0/0" >&2
  print_and_exit "0" "0" "0"
fi

module_path="$(go list -m 2>/dev/null)"
if [[ -z "${module_path}" ]]; then
  echo "changed-line coverage: 'go list -m' failed -- reporting 0/0" >&2
  print_and_exit "0" "0" "0"
fi

changed_lines_file="$(mktemp)"
trap 'rm -f "${changed_lines_file}"' EXIT

git diff --unified=0 "${base_ref}...HEAD" -- '*.go' 2>/dev/null | awk '
  /^\+\+\+ / {
    file = $2
    sub(/^b\//, "", file)
    next
  }
  /^@@/ {
    match($0, /\+[0-9]+/)
    newline = substr($0, RSTART + 1, RLENGTH - 1) + 0
    next
  }
  /^\+\+\+/ { next }
  /^\+/ {
    if (file !~ /_test\.go$/) print file "\t" newline
    newline++
    next
  }
' > "${changed_lines_file}"

if [[ ! -s "${changed_lines_file}" ]]; then
  print_and_exit "100" "0" "0"
fi

if [[ ! -f "${coverage_out}" ]]; then
  bash scripts/coverage.sh >/dev/null 2>&1 || true
fi

if [[ ! -f "${coverage_out}" ]]; then
  echo "changed-line coverage: no coverage profile at '${coverage_out}' and one could not be generated -- reporting 0/0" >&2
  print_and_exit "0" "0" "0"
fi

result="$(awk -v module="${module_path}/" '
  FNR == NR {
    if ($0 ~ /^mode:/) { next }
    if (NF < 3) { next }
    loc = $1
    split(loc, locparts, ":")
    file = locparts[1]
    sub(module, "", file)
    split(locparts[2], se, ",")
    split(se[1], sc, ".")
    split(se[2], ec, ".")
    startLine = sc[1] + 0
    endLine = ec[1] + 0
    count = $3 + 0
    key = file SUBSEP startLine SUBSEP endLine
    if (!(key in seen)) {
      seen[key] = 1
      blkFile[++n] = file
      blkStart[n] = startLine
      blkEnd[n] = endLine
      blkKey[n] = key
    }
    if (count > 0) blkCovered[key] = 1
    next
  }
  {
    changedFile[++m] = $1
    changedLine[m] = $2 + 0
  }
  END {
    total = 0
    covered = 0
    for (i = 1; i <= m; i++) {
      f = changedFile[i]
      l = changedLine[i]
      found = 0
      isCov = 0
      for (j = 1; j <= n; j++) {
        if (blkFile[j] == f && blkStart[j] <= l && l <= blkEnd[j]) {
          found = 1
          if (blkKey[j] in blkCovered) isCov = 1
        }
      }
      if (found) {
        total++
        if (isCov) covered++
      }
    }
    if (total == 0) {
      print "100 0 0"
    } else {
      pct = (100.0 * covered) / total
      printf "%.1f %d %d\n", pct, covered, total
    }
  }
' "${coverage_out}" "${changed_lines_file}")"

if [[ -z "${result}" ]]; then
  echo "changed-line coverage: intersection computation produced no result -- reporting 0/0" >&2
  print_and_exit "0" "0" "0"
fi

read -r pct covered total <<<"${result}"
print_and_exit "${pct}" "${covered}" "${total}"
