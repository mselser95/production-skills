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
# WHAT "SATISFIED ONLY BY COMMENTS" MEANS HERE (two rules, added 2026-10-06)
#
#   SCOPE.     A pattern is judged in the files its OWN probe grep searches: the
#              --include=/--exclude= globs and explicit path arguments written on
#              that grep invocation (or its backslash continuation lines) are
#              carried along with the pattern. Where the grep has no explicit
#              scope, the default is *.go minus *_test.go. Where a scope token is
#              not statically readable (a "$var" or "$@" path), the pattern is
#              searched in the default scope AND the output says so
#              ("scope not determinable"); it is never skipped.
#   DIRECTIVES. A line is a comment unless it is a compiler/tool DIRECTIVE, which
#              the toolchain acts on and a pattern about it can only ever match.
#              Directives, strictly anchored at the start of the line, no space
#              after `//` except for +build:  //go:<word> (build, embed, generate,
#              linkname, noinline, ...), `// +build <expr>`, //nolint, //lint:,
#              //export <name>. Everything else starting with // /* or * is prose.
#              "// go:build x" (with a space) is prose.
#
#   FLAGS.     -i on the probe's grep is carried (token "icase"); other flags are not.
#   GUARDED.   A grep the probe itself pipes through `code_lines_only` (on the same
#              logical line) already discards prose before it decides anything,
#              so prose-only matches are that row's designed answer (typically
#              NA "nothing here"), not a vacuous pass. Such a pattern is printed
#              as GUARDED and not counted as comment-only. A filter on a
#              LATER line is not seen, so that row is still reported.
#
# Debug: ROW_VACUITY_DEBUG=1 prints, per pattern, the scope used and the first
# evidence line to stderr. Test seam: the probe is read from
# <repo-root>/scripts/verify-standard.sh first, so a fixture repo brings its own.
#
# Usage: row-vacuity-sweep.sh [repo-root]   (default: cwd; run it in a repo that
#                                            has Go sources, e.g. an instantiated
#                                            template)
# Exit:  0 nothing comment-only · 1 at least one pattern is prose-only · 2 the
#        sweep could not run (no probe, no patterns extracted)
set -uo pipefail

root="${1:-$PWD}"
root="$(cd "$root" 2>/dev/null && pwd)" || { echo "row-vacuity-sweep: repo root not found: ${1:-}" >&2; exit 2; }
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
#
# THIRD DEFECT, 2026-10-06 (found in a service scaffolded from this template, where
# `make check-fast` failed at this sweep with "1 satisfied ONLY by comments"
# listing two `//go:build integration` lines in NON-test files). Two faults that
# compound: (1) SCOPE -- the integration-fidelity row greps build tags with
# `--include='*_test.go'`, while this sweep re-ran every pattern with a hard-coded
# `--include='*.go' --exclude='*_test.go'`: exactly the files the row does not
# look at, so the only hits were the unrelated tagged harness files and the row
# was called vacuous while its real evidence (tagged _test.go files) existed.
# (2) CLASSIFICATION -- every line starting `//` was called a comment, though
# `//go:build` is a directive the compiler acts on. A sweep that judges a pattern
# in a different place than the probe looks, and mislabels what it finds, is the
# first two defects again in a new shape: the instrument measured something other
# than the row. Fixed by carrying each grep's scope with its pattern and by the
# DIRECTIVES rule in the header.
#
# Each record is  pattern<TAB>scope  where scope is a space-separated list of
# (The pattern may follow a quoted "${ARRAY[@]}" of extra grep flags -- as in the
# probe's PROBE_GREP_EXCLUDES -- or `-e`; before 2026-10-06 that form was read as
# a pattern named "${PROBE_GREP_EXCLUDES[@]}" and the real pattern skipped. A
# pattern quoted with ' may contain " and vice versa.)
# inc:<glob> exc:<glob> path:<p> tokens (plus "guarded", see GUARDED), or "-" when the grep names none; a "?"
# token marks a scope token that could not be read statically (e.g. "${1:-.}"):
# the readable globs are still honoured, the path falls back to ".", and the
# output says so.
extract() {
  grep -v '^[[:space:]]*#' "$probe" \
    | awk '{ if (sub(/\\[[:space:]]*$/, " ")) { acc = acc $0; next } print acc $0; acc = "" } END { if (acc != "") print acc }' \
    | while IFS= read -r line; do
        while [[ $line =~ grep\ -r([a-zA-Z]*)\ (\"\$\{[A-Za-z_]+\[@\]\}\"\ |-e\ )?(\'([^\']+)\'|\"([^\"]+)\")(.*)$ ]]; do
          flg="${BASH_REMATCH[1]}"; pat="${BASH_REMATCH[4]}${BASH_REMATCH[5]}"; rest="${BASH_REMATCH[6]}"; line="$rest"
          full="${rest%%grep -r*}"; guard=""
          [[ $full == *code_lines_only* ]] && guard="guarded "
          seg="${rest%%|*}"; seg="${seg%%;*}"; seg="${seg%%&&*}"; seg="${seg%%)*}"
          seg="${seg%%grep -r*}"
          scope="" undet=0
          set -f
          for tok in $seg; do
            t="${tok//[\'\"]/}"
            case "$tok" in
              --include=*) scope+="inc:${t#--include=} " ;;
              --exclude=*) scope+="exc:${t#--exclude=} " ;;
              --|-*)       ;;
              [0-9]*[\<\>]*|[\<\>]*) ;;
              *)  if [[ $t =~ ^[A-Za-z0-9_./-]+$ && $t != /* && $t != *..* ]]; then scope+="path:$t "; else undet=1; fi ;;
            esac
          done
          set +f
          (( undet )) && scope+="? "
          scope+="$guard"
          [[ $flg == *i* ]] && scope+="icase "
          printf '%s\t%s\n' "$pat" "${scope:--}"
        done
      done | sort -u
}
mapfile -t recs < <(extract)

if (( ${#recs[@]} == 0 )); then
  echo "row-vacuity-sweep: extracted ZERO patterns from $probe -- a sweep with no subjects is not a clean sweep" >&2
  exit 2
fi

comment_only=0 checked=0 nomatch=0
for rec in "${recs[@]}"; do
  p="${rec%%$'\t'*}"; scope="${rec#*$'\t'}"
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
  sargs=() paths=() sdesc="" note="" hasinc=0 hasexc=0 undet=0 guarded=0
  set -f
  for t in $scope; do
    case "$t" in
      inc:*) sargs+=(--include="${t#inc:}"); hasinc=1 ;;
      exc:*) sargs+=(--exclude="${t#exc:}"); hasexc=1 ;;
      path:*) paths+=("${t#path:}") ;;
      '?') undet=1 ;;
      guarded) guarded=1 ;;
      icase) sargs+=(-i) ;;
    esac
  done
  set +f
  if (( !hasinc && !hasexc && ${#paths[@]} == 0 )); then
    sargs=(--include='*.go' --exclude='*_test.go'); sdesc="default: *.go minus *_test.go"
  else
    (( hasinc )) || sargs+=(--exclude-dir=.git)
    sdesc="$scope"
  fi
  if (( undet )); then
    sdesc="$sdesc (scope not determinable)"; note=" [scope not fully determinable: readable parts used, rest defaulted]"
  fi
  (( ${#paths[@]} )) || paths=(.)
  hits=$( { grep -rn  "${sargs[@]}" -- "$p" "${paths[@]}" 2>/dev/null
            grep -rnE "${sargs[@]}" -- "$p" "${paths[@]}" 2>/dev/null
          } | sort -u | head -200)
  [[ -n "$hits" ]] || { [[ -n "${ROW_VACUITY_DEBUG:-}" ]] && printf 'DEBUG %s -> [%s] -> no match\n' "$p" "$sdesc" >&2; nomatch=$((nomatch + 1)); continue; }
  checked=$((checked + 1))
  # A comment line here is `path:NN:<whitespace>//...` (or `#...` outside .go files), unless it is a directive
  # (see the DIRECTIVES rule in the header), which counts as evidence.
  code=$(printf '%s\n' "$hits" | awk '{
      rest = $0; sub(/^[^:]*:[0-9]+:/, "", rest)
      if (rest ~ /^[ \t]*(\/\/go:[a-z]|\/\/ [+]build[ \t]|\/\/nolint|\/\/lint:|\/\/export[ \t])/) { print; exit }
      if (rest ~ /^[ \t]*(\/\/|\/\*|\*)/) next
      f = $0; sub(/:[0-9]+:.*$/, "", f)
      if (f !~ /\.go$/ && rest ~ /^[ \t]*#/) next
      print; exit }')
  [[ -n "${ROW_VACUITY_DEBUG:-}" ]] && printf 'DEBUG %s -> [%s] -> %s\n' "$p" "$sdesc" "${code:-$(printf '%s\n' "$hits" | head -1) (comment)}" >&2
  if [[ -z "$code" ]] && (( guarded )); then
    printf '  GUARDED       %-46s prose-only, but the probe pipes this grep through code_lines_only (not counted)\n' "$p"
  elif [[ -z "$code" ]]; then
    n=$(printf '%s\n' "$hits" | wc -l | tr -d ' ')
    printf '  COMMENT-ONLY  %-46s %s match(es), every one a comment%s\n' "$p" "$n" "$note"
    printf '%s\n' "$hits" | head -2 | sed 's/^/                  /'
    comment_only=$((comment_only + 1))
  fi
done

echo
echo "row-vacuity-sweep: ${#recs[@]} pattern(s) extracted, ${checked} with matches, ${nomatch} with none, ${comment_only} satisfied ONLY by comments."
if (( comment_only > 0 )); then
  echo "  A check whose only evidence is prose is the shape that let tracing-wired-in-prod"
  echo "  pass with the tracer never injected. Pipe the grep through code_lines_only." >&2
  exit 1
fi
exit 0
