#!/usr/bin/env bash
# prove-mutation.sh — apply ONE mutation, run ONE test command, always revert,
# and say what happened in ONE line.
#
# WHY THIS EXISTS
#
# It is a token budget, not a convenience. Measured 2026-10-02 over 69
# prod-implementer transcripts: implementers proved each task's mutation RED by
# hand -- edit, launch the test in the background, `sleep`/`until`/`pgrep` until
# it finished, tail the log, revert -- and 7% of all their Bash calls were those
# waiting laps. Every lap is a model turn that re-reads the agent's whole
# context (median 150k+, up to 965k tokens). This script turns that loop into
# one call and one line of output.
#
# THE BASELINE RUN IS NOT OPTIONAL BY DEFAULT. A test that already fails on the
# unmutated tree goes "RED" under any mutation, and reporting that as proof is
# the vacuous-gate defect this repo refuses everywhere else. So the command is
# run first on the clean tree and must pass; only then is the mutation applied.
# `--no-baseline` exists for callers that have JUST run the same command green
# and say so in their evidence.
#
# THE REVERT IS NOT A BEST EFFORT. The patch is reverted from a trap, and the
# touched files' content hashes are compared before and after: a revert that
# leaves the tree different is ERROR, never a verdict, because a mutation left
# behind in the tree is worse than no proof at all.
#
# Usage: prove-mutation.sh [--no-baseline] [--expect REGEX] PATCH -- CMD [ARGS...]
#   PATCH     a unified diff, applied with `git apply` from the repo root
#   CMD       the test command; non-zero exit on the mutated tree = RED
#   --expect  RED additionally requires REGEX to match the mutated run's output
#             (e.g. the test's name), so a mutation that merely breaks the
#             build does not count as the test detecting it
# Output: exactly one line on stdout:
#   RED   <patch> exit=<n> log=<path>
#   GREEN <patch> exit=0 log=<path>          -- the mutation survived
#   ERROR <reason>
# Exit:  0 RED · 1 GREEN · 2 ERROR (baseline red, patch did not apply,
#        --expect unmatched, revert failed, bad usage)
set -uo pipefail

baseline=1 expect=""
while (( $# )); do
  case "$1" in
    --no-baseline) baseline=0; shift ;;
    --expect) expect="${2:-}"; shift 2 ;;
    --) break ;;
    -*) echo "ERROR unknown flag $1"; exit 2 ;;
    *) break ;;
  esac
done
patch="${1:-}"; shift || true
[[ "${1:-}" == "--" ]] && shift
if [[ -z "$patch" || $# -eq 0 ]]; then
  echo "ERROR usage: prove-mutation.sh [--no-baseline] [--expect REGEX] PATCH -- CMD [ARGS...]"
  exit 2
fi
[[ -f "$patch" ]] || { echo "ERROR patch not found: $patch"; exit 2; }
patch="$(cd "$(dirname "$patch")" && pwd)/$(basename "$patch")"

root="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "ERROR not inside a git repository"; exit 2; }
cd "$root" || { echo "ERROR cannot cd to $root"; exit 2; }

log="$(mktemp "${TMPDIR:-/tmp}/prove-mutation.XXXXXX")"

if ! git apply --check "$patch" 2>>"$log"; then
  echo "ERROR patch does not apply cleanly: $patch log=$log"; exit 2
fi
# A read loop, not mapfile: macOS still ships bash 3.2 as /bin/bash, where
# mapfile does not exist, and an empty `touched` would make the revert check
# below compare nothing to nothing and pass.
touched=()
while IFS= read -r f; do [[ -n "$f" ]] && touched+=("$f"); done \
  < <(git apply --numstat "$patch" | awk '{ print $3 }')
if (( ${#touched[@]} == 0 )); then
  echo "ERROR patch touches no files: $patch"; exit 2
fi
snapshot() { local f; for f in "${touched[@]}"; do if [[ -e "$f" ]]; then git hash-object "$f"; else echo "absent $f"; fi; done; }
before="$(snapshot)"

if (( baseline )); then
  echo "== baseline: $*" >>"$log"
  if ! "$@" >>"$log" 2>&1; then
    echo "ERROR baseline is already red, so RED would prove nothing log=$log"; exit 2
  fi
fi

applied=0
revert() {
  if (( applied )); then
    git apply -R "$patch" 2>>"$log" || true
    applied=0
  fi
}
trap revert EXIT INT TERM

git apply "$patch" 2>>"$log" || { echo "ERROR patch failed to apply log=$log"; exit 2; }
applied=1

echo "== mutated: $*" >>"$log"
mutated_out="$(mktemp "${TMPDIR:-/tmp}/prove-mutation-run.XXXXXX")"
"$@" >"$mutated_out" 2>&1
rc=$?
cat "$mutated_out" >>"$log"

revert
trap - EXIT INT TERM
if [[ "$(snapshot)" != "$before" ]]; then
  echo "ERROR revert left the tree changed -- inspect ${touched[*]} log=$log"; exit 2
fi

if (( rc == 0 )); then
  rm -f "$mutated_out"
  echo "GREEN $patch exit=0 log=$log"; exit 1
fi
if [[ -n "$expect" ]] && ! grep -Eq -- "$expect" "$mutated_out"; then
  rm -f "$mutated_out"
  echo "ERROR mutated run failed (exit=$rc) but output never matched --expect '$expect' -- likely a build break, not a detection log=$log"; exit 2
fi
rm -f "$mutated_out"
echo "RED   $patch exit=$rc log=$log"
exit 0
