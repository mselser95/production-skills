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
#
# ONE exception, and it is a refusal, not a measurement failure: the optional
# CHANGED_LINE_EXTRA_EXCLUDES (below) exits non-zero on a malformed entry, and
# when it is set a git failure computing the diff is a refusal too, never a
# percentage.
#
# CHANGED_LINE_EXTRA_EXCLUDES (optional, default unset): extra git pathspec
# exclusions, whitespace- or newline-separated, appended to the pathspec of the
# diff that defines the changed-line set. Every entry must start with ':!' or
# ':(exclude'; anything else is refused (exit 2, entry named) because a bare
# path in that position would INCLUDE instead of exclude and silently change
# what is measured. An entry that passes that check is then handed to git itself
# (`git ls-files -- '*.go' <entries>`): git exits 128 with a 'fatal:' message on
# a pathspec it rejects (checked on git 2.53.0 only: ':!'q' = unimplemented
# magic, ':(exclude,foo)x' = invalid magic, ':(exclude' = missing ')'), and any
# non-zero status there is refused (exit 2, git's message printed). When set and non-empty one line naming the exclusions is
# printed before the summary; when unset or empty the output is byte-identical
# to a run without it. It is set by `make acceptance-audit` (from
# ACCEPTANCE_AUDIT_EXCLUDES), never by the unit-coverage signal: the audit asks
# whether DELIVERED code is exercised by the acceptance suite, and a test double
# or another suite's harness that is not a _test.go file is not delivered code
# and cannot be reached by an acceptance run that uses the real implementation.
# A tier-0 repo scaffolded from this template measured 20 of 30 changed lines
# executed: 20 of 22 in delivered code, 0 of 8 in test-support files.
set -u

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 0

base_ref="${CHANGED_LINE_COVERAGE_BASE:-origin/main}"
coverage_out="${COVERAGE_OUT:-coverage.out}"

extra_excludes=()
if [[ -n "${CHANGED_LINE_EXTRA_EXCLUDES:-}" ]]; then
  set -f
  for entry in ${CHANGED_LINE_EXTRA_EXCLUDES}; do
    case "${entry}" in
      ':!'*|':(exclude'*) extra_excludes+=("${entry}") ;;
      *)
        set +f
        echo "changed-line coverage: refusing CHANGED_LINE_EXTRA_EXCLUDES entry '${entry}': each entry must start with ':!' or ':(exclude'" >&2
        exit 2
        ;;
    esac
  done
  set +f
  if (( ${#extra_excludes[@]} > 0 )); then
    if ! git_err="$(git ls-files -- '*.go' "${extra_excludes[@]}" 2>&1 >/dev/null)"; then
      echo "changed-line coverage: refusing CHANGED_LINE_EXTRA_EXCLUDES: git rejected the pathspec: ${git_err}" >&2
      exit 2
    fi
    echo "changed-line coverage: excluding from the changed-line set: ${extra_excludes[*]}"
  fi
fi

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

awk_prog='
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
'

if (( ${#extra_excludes[@]} == 0 )); then
  git diff --unified=0 "${base_ref}...HEAD" -- '*.go' 2>/dev/null | awk "${awk_prog}" > "${changed_lines_file}"
else
  # Exclusions set: a git failure here is a refusal, never a percentage.
  diff_err="$(mktemp)"
  if ! diff_out="$(git diff --unified=0 "${base_ref}...HEAD" -- '*.go' "${extra_excludes[@]}" 2>"${diff_err}")"; then
    echo "changed-line coverage: refusing: git diff failed with CHANGED_LINE_EXTRA_EXCLUDES set: $(cat "${diff_err}")" >&2
    rm -f "${diff_err}"
    exit 2
  fi
  rm -f "${diff_err}"
  printf '%s\n' "${diff_out}" | awk "${awk_prog}" > "${changed_lines_file}"
fi

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
