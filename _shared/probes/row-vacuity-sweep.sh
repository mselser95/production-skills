#!/usr/bin/env bash
# row-vacuity-sweep.sh — which of verify-standard.sh's presence checks are
# currently satisfied ONLY by comments?
#
# WHY THIS EXISTS
#
# On 2026-08-29 three PASSing rows were mutation-tested at random and all three
# turned out to be satisfiable by prose:
#
#   tracing-wired-in-prod               a comment naming NewTracer, plus a func
#                                       DECLARATION counted as a call site
#   observability:log_handler_installed a comment naming slog.NewMultiHandler
#   profiling (live half)               three comment lines naming net/http/pprof
#
# Three for three. At that base rate, sampling is not a strategy: the remaining
# presence checks needed a mechanical answer, not another random draw.
#
# WHAT IT DOES. It extracts every `grep -r...` pattern that verify-standard.sh
# uses over source, runs each against the repo, and reports any whose matches
# are ENTIRELY comment lines. A pattern in that state is a check whose evidence
# today is prose — the exact condition the three fixed rows were in.
#
# WHAT IT DOES NOT DO, stated plainly rather than implied: it does not prove a
# row is non-vacuous. A pattern with real code matches can still be satisfied by
# the wrong code (a declaration rather than a call — the second sub-shape found
# that day), and rows that execute something, count ratios, or read YAML are out
# of scope entirely. This answers ONE question mechanically, and the answer
# "nothing is comment-only right now" is worth having precisely because it can
# change with the next commit.
#
# Usage: row-vacuity-sweep.sh [repo-root]   (default: cwd; run it in a repo that
#                                            has Go sources, e.g. an instantiated
#                                            template)
# Exit:  0 nothing comment-only · 1 at least one pattern is prose-only · 2 the
#        sweep could not run (no probe, no patterns extracted)
set -uo pipefail

root="${1:-$PWD}"
probe=""
for cand in "$root/scripts/verify-standard.sh" \
            "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/verify-standard.sh"; do
  [[ -r "$cand" ]] && { probe="$cand"; break; }
done
[[ -n "$probe" ]] || { echo "row-vacuity-sweep: no verify-standard.sh found" >&2; exit 2; }
cd "$root" || exit 2

# Every quoted pattern handed to a recursive grep in the probe -- FROM CODE
# LINES ONLY.
#
# The `grep -v '^[[:space:]]*#'` is not tidiness. Without it this script read
# patterns out of the probe's own COMMENTS, and its first run duly reported a
# finding against `wire\|golden\|protoreflect\|unknown.field` -- a pattern that
# appears at verify-standard.sh:1071 inside the sentence "This row used to be
# `grep -rql ...`", describing a version replaced long ago. The live check is at
# :1095 and is far tighter.
#
# So the vacuity sweep counted comments as code: precisely the defect it was
# written to detect, in itself, on its first execution. Recorded here rather
# than quietly patched, because it is the cleanest possible demonstration of why
# the class is easy to miss -- I wrote this file specifically to hunt that shape
# and reproduced it inside it within the hour.
#
# Deliberately crude otherwise: this is a triage instrument, and a pattern it
# cannot extract is simply not swept, which the count below makes visible.
mapfile -t pats < <(grep -v '^[[:space:]]*#' "$probe" \
  | grep -oE "grep -r[a-zA-Z]* ['\"][^'\"]+['\"]" \
  | sed -E "s/^grep -r[a-zA-Z]* ['\"]//; s/['\"]$//" | sort -u)

if (( ${#pats[@]} == 0 )); then
  echo "row-vacuity-sweep: extracted ZERO patterns from $probe -- a sweep with no subjects is not a clean sweep" >&2
  exit 2
fi

comment_only=0 checked=0 nomatch=0
for p in "${pats[@]}"; do
  # Skip patterns that are plainly not source probes.
  [[ ${#p} -lt 3 ]] && continue

  # BOTH DIALECTS, unioned. The first version ran only `grep -rn` (BRE) while
  # most of the probe's patterns come from `grep -rnE` and are ERE. An ERE
  # pattern like `slog\.(New(JSON|Text)Handler|NewMultiHandler|SetDefault)`
  # matches NOTHING under BRE, so the sweep counted it as "no matches" and moved
  # on -- silently. Measured 2026-08-29: of 29 extracted patterns it reported
  # "23 with none", and most of those 23 were this, not an absent subject.
  #
  # So the vacuity sweep was itself vacuous: it reported a clean result over a
  # set it had never actually searched. That is the second defect of exactly the
  # class this file hunts, found inside this file, within an hour of the first
  # (patterns lifted from the probe's own comments). Both are recorded rather
  # than quietly fixed, because the pattern is the lesson: an instrument that
  # reports "nothing found" has to be shown finding something before the
  # "nothing" means anything.
  hits=$( { grep -rn  --include='*.go' --exclude='*_test.go' -- "$p" . 2>/dev/null
            grep -rnE --include='*.go' --exclude='*_test.go' -- "$p" . 2>/dev/null
          } | sort -u | head -200)
  [[ -n "$hits" ]] || { nomatch=$((nomatch + 1)); continue; }
  checked=$((checked + 1))
  # A comment line here is `path:NN:<whitespace>//...`.
  code=$(printf '%s\n' "$hits" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(//|/\*|\*)' | head -1)
  if [[ -z "$code" ]]; then
    n=$(printf '%s\n' "$hits" | wc -l | tr -d ' ')
    printf '  COMMENT-ONLY  %-46s %s match(es), every one a comment\n' "$p" "$n"
    printf '%s\n' "$hits" | head -2 | sed 's/^/                  /'
    comment_only=$((comment_only + 1))
  fi
done

echo
echo "row-vacuity-sweep: ${#pats[@]} pattern(s) extracted, ${checked} with matches, ${nomatch} with none, ${comment_only} satisfied ONLY by comments."
if (( comment_only > 0 )); then
  echo "  A check whose only evidence is prose is the shape that let tracing-wired-in-prod"
  echo "  pass with the tracer never injected. Pipe the grep through code_lines_only." >&2
  exit 1
fi
exit 0
