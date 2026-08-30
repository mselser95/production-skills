#!/usr/bin/env bash
# probe-wiring.sh — every probe this repo ships must be INVOKED by something.
#
# WHY THIS EXISTS, measured rather than imagined.
#
# On 2026-08-29 this repo shipped eleven probes. One of them,
# _shared/probes/row-vacuity-sweep.sh, was invoked by CI zero times and by the
# pre-commit hook zero times -- while being wired into
# prod-new/template/Makefile, so that every repo SCAFFOLDED from here ran it
# faithfully. The framework vended a gate it did not run on itself.
# check-registries.sh had the same shape: its selftest ran in CI, the check
# itself never looked at this repo's own four registries.
#
# Neither was findable by reading. Both probes PASSED when finally run, so
# there was no red to notice, and an unwired gate and a passing gate print the
# same thing: nothing. The mapping that found them was built by hand -- which
# means it decays the moment somebody adds probe number twelve.
#
# That is dimension 16 of the standard ("mechanisms are DRIVEN, not merely
# present") turned on this repo itself. A mechanism nothing invokes is not a
# weaker version of a gate; it is a document that looks like a gate, and it is
# strictly worse than no gate because the repo believes it is covered.
#
# WHAT COUNTS AS AN INVOKER: the Makefile, the CI workflows, the git hooks.
# Being named in a COMMENT does not count -- that is the comment-as-code defect
# this repo has now recorded six times -- so every candidate line is stripped of
# comments before it is searched.
#
# Exit: 0 every probe is invoked · 1 one or more are orphaned · 2 refused to answer
set -uo pipefail

# BASH 4+ REQUIRED, said out loud rather than discovered as a wrong answer.
#
# This script uses `mapfile` and `declare -A`, both bash 4. macOS still ships
# bash 3.2 as /bin/bash, and under it this file does not merely fail -- it fails
# with the WRONG REASON. Measured 2026-08-29: `mapfile: command not found`, then
# `SURFACES: unbound variable`, and finally the honest-looking verdict "every
# invoker surface is empty after stripping comments -- refusing to report",
# which sends the reader to look for a broken Makefile that is perfectly fine.
#
# It failed closed, which is the right direction and not good enough: a right
# verdict with a guessed cause costs the next person an hour. Requiring bash 4
# is house style here (verify-standard.sh, row-vacuity-sweep.sh,
# validate-demo.sh and four others already do); naming the requirement is the
# part that was missing.
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  echo "probe-wiring: needs bash 4+ (uses mapfile and associative arrays); this is bash ${BASH_VERSION:-unknown}." >&2
  echo "  On macOS /bin/bash is 3.2. Run it with a newer bash (brew install bash), which is" >&2
  echo "  what /usr/bin/env bash resolves to for every other probe in this repo." >&2
  exit 2
fi

cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" || exit 2

PROBE_DIR="${1:-_shared/probes}"
PROBE_DIR="${PROBE_DIR%/}"   # `scripts/` and `scripts` must name the same dir;
                             # find would otherwise emit `scripts//x.sh` and no
                             # exception key could ever match it.
[[ -d "$PROBE_DIR" ]] || { echo "probe-wiring: no $PROBE_DIR -- nothing to check, which is not a pass" >&2; exit 2; }

# The invoker surfaces. A probe is wired if any of these EXECUTES it.
mapfile -t SURFACES < <(
  { [[ -f Makefile ]] && echo Makefile
    find .github/workflows -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) 2>/dev/null
    find .githooks -maxdepth 1 -type f 2>/dev/null
  } | sort -u
)
if (( ${#SURFACES[@]} == 0 )); then
  echo "probe-wiring: found ZERO invoker surfaces (no Makefile, no workflows, no hooks)." >&2
  echo "  Every probe would be reported orphaned, which measures this script, not the repo." >&2
  exit 2
fi

# Comment-stripped body of every surface, concatenated once. Shell and YAML both
# use '#', so one filter serves both. Anchoring on '^[[:space:]]*#' keeps a '#'
# that appears mid-line (a URL fragment, a printf) from eating real code.
haystack=$(cat "${SURFACES[@]}" 2>/dev/null | sed 's/^[[:space:]]*#.*$//')
[[ -n "${haystack//[[:space:]]/}" ]] || {
  echo "probe-wiring: every invoker surface is empty after stripping comments -- refusing to report" >&2
  exit 2
}

mapfile -t PROBES < <(find "$PROBE_DIR" -name '*.sh' -type f | sort)
if (( ${#PROBES[@]} == 0 )); then
  echo "probe-wiring: found ZERO probes in $PROBE_DIR -- a clean result over nothing is not a clean result" >&2
  exit 2
fi

# DECLARED EXCEPTIONS: probes this repo ships and deliberately does not run.
# There is exactly one, and it is the whole reason this list exists rather than
# a silent exclusion.
#
#   verify-standard.sh implements the GO toolchain and REFUSES to run here
#   (`detected 'unknown'`, exit 2). This repo is shell and markdown. The probe
#   is EDITED here and EXECUTED in scaffolded repos, where the template's
#   Makefile drives it -- so it is not an orphan, it is a vended artifact whose
#   invoker lives downstream.
#
# Each entry carries its reason, and an entry naming a probe that no longer
# exists is an ERROR rather than a no-op: an exception list that can accumulate
# dead entries eventually excuses something nobody decided to excuse.
# Keyed by PATH, not basename, and that was a defect found by review on
# 2026-08-29. With basename keys the staleness check fired for ANY directory
# this probe was pointed at: `probe-wiring.sh scripts/` exited 2 complaining
# that verify-standard.sh "does not exist in scripts/" -- which is true and not
# a finding, since that exception was never about scripts/. The tool took a
# directory argument it could not actually serve.
#
# A path key also says which tree the excuse belongs to, so an exception is
# checked for staleness only when its own directory is the one being scanned.
declare -A EXCEPT=(
  [_shared/probes/verify-standard.sh]="Go-only probe, refuses to run on this repo (exit 2); executed in scaffolded repos via the template Makefile"
)
for e in "${!EXCEPT[@]}"; do
  # Out of scope for this run rather than stale: an exception for another tree
  # is not an excuse this scan could be honouring.
  [[ "$(dirname "$e")" == "$PROBE_DIR" ]] || continue
  if ! printf '%s\n' "${PROBES[@]}" | grep -qxF -- "$e"; then
    echo "probe-wiring: declared exception '$e' names a probe that does not exist." >&2
    echo "  A stale exception silently excuses a gate nobody decided to excuse. Remove it." >&2
    exit 2
  fi
done

# Glob tokens harvested from the invoker surfaces: any whitespace-delimited word
# that ends in .sh and contains a '*'. Narrow on purpose -- a bare '*' or a '*.sh'
# with no other structure would match every probe and turn this gate into a
# rubber stamp, so those are dropped and reported rather than honoured.
mapfile -t GLOBS < <(grep -oE '[^[:space:]"'"'"']*\*[^[:space:]"'"'"']*\.sh' <<<"$haystack" \
  | sed 's|.*/||' | sort -u)
declare -a USABLE_GLOBS=()
for g in "${GLOBS[@]:-}"; do
  [[ -n "$g" ]] || continue
  # Require at least three literal characters besides the star and the .sh, so
  # `*.sh` cannot excuse everything.
  lit="${g//\*/}"; lit="${lit%.sh}"
  (( ${#lit} >= 3 )) && USABLE_GLOBS+=("$g")
done

glob_covers() { # basename -> 0 if some harvested glob matches it
  local name="$1" g
  for g in "${USABLE_GLOBS[@]:-}"; do
    [[ -n "$g" ]] || continue
    # Unquoted on purpose: pattern matching is the point here.
    # shellcheck disable=SC2053
    [[ "$name" == $g ]] && return 0
  done
  return 1
}

orphans=(); wired=0; excused=0
for p in "${PROBES[@]}"; do
  b=$(basename "$p")
  if [[ -n "${EXCEPT[$p]:-}" ]]; then
    excused=$((excused + 1))
    continue
  fi
  # Matched by BASENAME, not full path: the Makefile reaches probes through
  # $(PROBES)/x.sh, so a path-literal search would report every one orphaned.
  #
  # DELIMITED, and a plain substring match was WRONG. `grep -qF "$b"` reported
  # an orphan as wired whenever its basename was a substring of a wired one:
  # measured 2026-08-29 by adding `_shared/probes/wiring.sh`, which nothing
  # invokes, and watching this probe exit 0 because the Makefile contains
  # `probe-wiring.sh`. A gate reporting covered over exactly the condition it
  # exists to detect is the worst outcome available to it -- worse than not
  # existing, because the repo now believes the question is answered.
  #
  # The delimiter class is "anything that cannot be part of a filename here":
  # a path separator, whitespace, a quote. Anchored at both ends, so
  # `wiring.sh` no longer matches inside `probe-wiring.sh`, while
  # `$(PROBES)/check-registries.sh` and `bash _shared/probes/x.sh` still do.
  b_re=$(printf '%s' "$b" | sed 's/[.[\*^$()+?{|]/\\&/g')
  if grep -qE "(^|[/[:space:]\"'])${b_re}([[:space:]\"']|\$)" <<<"$haystack"; then
    wired=$((wired + 1))
  elif glob_covers "$b"; then
    # A GLOB IS A REAL INVOCATION. The Makefile runs the selftests as
    # `$(PROBES)/*-selftest.sh`, deliberately, so that a selftest added tomorrow
    # cannot be silently omitted from a hand-maintained list. A literal-only
    # matcher calls every one of those an orphan -- measured 2026-08-29, this
    # probe reported its OWN freshly added selftest unwired while `make
    # selftests` was running it.
    #
    # That direction of error is the expensive one. An orphan missed is a gap
    # this probe fails to find; a false orphan is a red on healthy work, and a
    # gate that cries wolf gets deleted rather than fixed.
    wired=$((wired + 1))
  else
    orphans+=("$p")
  fi
done

if (( ${#orphans[@]} > 0 )); then
  echo "probe-wiring: ${#orphans[@]} of ${#PROBES[@]} probe(s) are invoked by NOTHING." >&2
  printf '  orphaned: %s\n' "${orphans[@]}" >&2
  echo "  A gate nothing runs is a document that looks like a gate. Wire it into the" >&2
  echo "  Makefile, or delete it -- an unwired probe is worse than an absent one," >&2
  echo "  because the repo believes it is covered." >&2
  exit 1
fi

echo "probe-wiring: ok -- ${wired} invoked + ${excused} declared-exception of ${#PROBES[@]} probe(s), across ${#SURFACES[@]} surface(s) (comments not counted)"
# Only the ones this scan could have honoured. Printing an out-of-scope
# exception makes the report claim an excuse it never applied.
for e in "${!EXCEPT[@]}"; do
  [[ "$(dirname "$e")" == "$PROBE_DIR" ]] || continue
  echo "  excused: $e -- ${EXCEPT[$e]}"
done
