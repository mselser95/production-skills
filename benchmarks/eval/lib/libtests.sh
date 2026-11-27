#!/usr/bin/env bash
# libtests.sh [corpus-root] -- run every executable corpus/*/_lib/*-selftest.sh.
# A corpus helper (shared grader code) that ships a selftest has it run by
# `make eval`; a failing one fails the target. Finding none is fine (prints it).
# Exit: 0 all passed (or none) | 1 a selftest failed
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
root="${1:-$here/corpus}"
n=0 bad=0 log="$(mktemp "${TMPDIR:-/tmp}/eval-libtest.XXXXXX")"
trap 'rm -f "$log"' EXIT
for f in "$root"/*/_lib/*-selftest.sh; do
  [[ -f "$f" && -x "$f" ]] || continue
  n=$((n + 1))
  if (cd "$(dirname "$f")" && bash "$f") >"$log" 2>&1; then
    printf '  ok    %s\n' "${f#"$root"/}"
  else
    printf '  FAIL  %s\n' "${f#"$root"/}"; tail -n 8 "$log"; bad=$((bad + 1))
  fi
done
if (( bad )); then echo "libtests: $bad of $n failed" >&2; exit 1; fi
echo "libtests: ok -- $n corpus helper selftest(s)"
