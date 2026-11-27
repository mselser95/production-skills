#!/usr/bin/env bash
# run-once.sh -- run a gate or a selftest suite exactly ONCE and record the outcome,
# so a later step can ATTEST to it instead of running it again.
#
# WHY THIS EXISTS
#
# One CI run executed the same gate or selftest suite three or four times: `make
# check-fast` and `make selftests`, again inside mutation-baseline.sh (which ran
# every suite to count its cases), again as a GATES entry of `make evidence`, and
# once more as named workflow steps. Measured on the `gates` job: 847 s, of which
# `make evidence` alone was 484 s, almost all of it re-execution.
#
# The repetition had a reason: a record assembled from another step's exit codes
# attests to what the YAML says ran, not to what ran. This file keeps that property
# by a different mechanism. The one who EXECUTES a gate is the one who writes its
# line, and the line carries everything needed to refuse a stale or foreign one:
# the command string, the exit code, a hash of the combined output, the tree
# identity (HEAD plus clean, or dirty plus a hash of the dirty content) measured
# before AND after the command, the run id and the time. A reader (`resolve`) trusts
# a line only when every one of those matches what it is about to claim.
#
# RESULTS FILE: ${EVIDENCE_RESULTS:-.evidence/results.tsv}, one TSV line per run,
# twelve columns, no header:
#   v1 | id | command | exit | duration_ms | output_sha256 | utc | epoch | tree | run | count | evidence
# `tree` is `<HEAD>+clean`, `<HEAD>+dirty-<sha256>` or `<HEAD>+unstable` (the
# command changed the tree while it ran: never attestable). `run` is
# ${EVIDENCE_RUN_ID:-local}. `count` is the suite's own case count (only with
# --count). Keep the file under .evidence/ or outside the tree: a results file inside
# the tree is itself a change to it.
#
# Usage:
#   run-once.sh [--quiet] [--count] [--as <command string>] <id> -- <command...>
#       runs once; exit code = the command's. --quiet prints nothing on success and the
#       last 20 lines on failure. --as records <command string> instead of the argv
#       (for a wrapper whose argv differs from the Makefile target it stands for).
#   run-once.sh tree-id            print the tree identity
#   run-once.sh count              stdin -> the suite's case count (exit 1 if none)
#   run-once.sh summary <rc>       stdin -> the one-line evidence of a gate's output
#   run-once.sh resolve <id> <cmd> print `attested<TAB>...` or `miss<TAB><reason>`
#   run-once.sh counts             print `<id><TAB><command><TAB><count>` for every trusted passing line
# Exit: the command's own (run) · 0 ok (others) · 1 nothing to report · 2 refused
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.." || exit 2

RESULTS="${EVIDENCE_RESULTS:-.evidence/results.tsv}"
RUN_ID="${EVIDENCE_RUN_ID:-local}"
# a line older than this is not "this run" on a developer machine, where the file
# outlives the run that wrote it. CI never gets near it.
MAX_AGE="${EVIDENCE_MAX_AGE:-3600}"

sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi; }

now_ms() { if [[ -n "${EPOCHREALTIME:-}" ]]; then local t=${EPOCHREALTIME/[.,]/}; echo "${t:0:13}"; else echo "$(date +%s)000"; fi; }

# The tree identity. .prod/evidence and .evidence are this tooling's own output
# directories, so their existence must not be what makes the tree dirty.
tree_id() {
  local head st untracked h
  head=$(git rev-parse HEAD 2>/dev/null) || { echo "run-once: not a git work tree with a HEAD" >&2; return 1; }
  st=$(git status --porcelain 2>/dev/null | grep -vE '^\?\? (\.prod/evidence|\.evidence)/?$' || true)
  if [[ -z "$st" ]]; then echo "${head}+clean"; return 0; fi
  untracked=$(git ls-files -o --exclude-standard 2>/dev/null | grep -vE '^(\.prod/evidence|\.evidence)/' || true)
  h=$({ printf '%s\n' "$st"; git diff HEAD 2>/dev/null
        if [[ -n "$untracked" ]]; then printf '%s\n' "$untracked" | git hash-object --stdin-paths 2>/dev/null; fi
      } | sha256)
  echo "${head}+dirty-${h}"
}

# The suite's own case count. mutation-baseline.sh's fallback (a suite with no
# recorded line) carries the same expression; scripts/tests/run-once-selftest.sh pins
# that the two agree on every summary shape. It takes the
# number that PRECEDES `ok` or `case`, anywhere on the line: suites word their
# summary differently ("12 ok, 0 failed", "60 case(s), every verdict...",
# "probe-self gate selftest: 29 ok"), and matching any integer would pick up the
# "0 failed".
count_of() { local n; n=$(grep -oE '[0-9]+ (ok|case)' | tail -1 | grep -oE '^[0-9]+' || true); [[ -n "$n" ]] || return 1; echo "$n"; }

# The last non-empty UNINDENTED line. Every gate here ends with its own summary at
# column 0 ("52 keys -- 52 scored", "TCB verified: 309 files") and puts detail
# underneath it indented. A plain `tail -1` captured the DETAIL instead:
# probe-wiring's record read "excused: verify-standard.sh ..." rather than "13
# invoked + 1 declared-exception of 15", which is the number a reader actually
# wants. Measured on the first run of the evidence recorder.
#
# A record holding rc and no evidence is a boolean pretending to be an attestation,
# so a gate that prints nothing on success is a gate to invoke through its Makefile
# target instead -- `make actionlint` says "workflows valid", bare actionlint says
# nothing at all.
# make's own recursion chatter is filtered as well as suppressed. CI runs GNU make
# 4.x, which prints `make[1]: Entering/Leaving directory '...'` around every
# sub-make; those lines are unindented, so the rule above picked THEM as the
# summary. Measured on run 33284769197: three of nine gates recorded "make[1]:
# Leaving directory '/home/runner/work/production-skills/...'" as their evidence.
# --no-print-directory is passed to those gates too, but it cannot be observed on
# macOS (GNU make 3.81 never emits the lines), so a filter is kept as well.
summary_of() {
  local rc="$1" out ev
  out=$(cat)
  ev=$(printf '%s\n' "$out" \
        | grep -vE "^make(\\[[0-9]+\\])?: (Entering|Leaving) directory" \
        | grep -vE '^[[:space:]]*$|^[[:space:]]+' | tail -1 || true)
  [[ -n "$ev" ]] || ev=$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -1 || true)
  [[ -n "$ev" ]] || ev="(gate produced no output; verdict from exit code $rc alone)"
  printf '%s' "$ev"
}

clean_field() { printf '%s' "$1" | tr '\t\r\n' '   ' | cut -c1-200; }

# resolve <id> <cmd>: decide whether the results file holds a line this run may
# attest to. Never prints `attested` unless exactly the same id, command string, tree
# identity and run id are on a well-formed line within MAX_AGE, and every such line
# agrees on the exit code.
resolve() {
  local id="$1" cmd="$2" tree
  [[ -e "$RESULTS" ]] || { printf 'miss\tno-results-file\n'; return 0; }
  [[ -s "$RESULTS" ]] || { printf 'miss\tempty-results-file\n'; return 0; }
  tree=$(tree_id) || { printf 'miss\tno-tree-identity\n'; return 0; }
  # values go through ENVIRON, not -v: awk -v interprets backslash escapes in them
  GR_ID="$id" GR_CMD="$cmd" GR_TREE="$tree" GR_RUN="$RUN_ID" GR_NOW="$(date +%s)" GR_MAXAGE="$MAX_AGE" awk -F'\t' '
    BEGIN { id = ENVIRON["GR_ID"]; cmd = ENVIRON["GR_CMD"]; tree = ENVIRON["GR_TREE"]; run = ENVIRON["GR_RUN"]; now = ENVIRON["GR_NOW"] + 0; maxage = ENVIRON["GR_MAXAGE"] + 0 }
    function hex(s) { return s ~ /^[0-9a-f]+$/ }
    function wellformed(   t) {
      if (NF != 12 || $1 != "v1" || $2 == "" || $3 == "") return 0
      if ($4 !~ /^[0-9]+$/ || $5 !~ /^[0-9]+$/ || $8 !~ /^[0-9]+$/) return 0
      if (length($6) != 64 || !hex($6)) return 0
      if ($9 !~ /^[0-9a-f]+\+(clean|unstable|dirty-[0-9a-f]+)$/) return 0
      if ($10 == "") return 0
      if ($11 != "" && $11 !~ /^[0-9]+$/) return 0
      return 1
    }
    NF == 0 { next }
    { seen++ }
    !wellformed() { bad = NR; next }
    $2 == id && $3 == cmd && $9 == tree && $10 == run && ($8 + 0) <= now + 300 && now - $8 <= maxage {
      if (matched && $4 != rc0) conflict = 1
      if (!matched) rc0 = $4
      matched++; line = NR; rc = $4; dur = $5; sha = $6; utc = $7; ev = $12
    }
    END {
      if (bad)      { printf "miss\tmalformed-results-file (line %d)\n", bad; exit }
      if (!seen)    { printf "miss\tempty-results-file\n"; exit }
      if (!matched) { printf "miss\tno-line-for-this-id-command-tree-run\n"; exit }
      if (conflict) { printf "miss\tconflicting-lines-for-this-id\n"; exit }
      printf "attested\t%s\t%d\t%s\t%s\t%s\t%s\n", rc, line, dur, sha, utc, ev
    }' "$RESULTS"
}

# counts: `<id><TAB><command><TAB><count>` for each id with exactly one outcome across its trusted
# lines, a zero exit, and a count. A malformed file yields nothing.
counts() {
  [[ -s "$RESULTS" ]] || return 0
  local tree; tree=$(tree_id) || return 0
  GR_TREE="$tree" GR_RUN="$RUN_ID" GR_NOW="$(date +%s)" GR_MAXAGE="$MAX_AGE" awk -F'\t' '
    BEGIN { tree = ENVIRON["GR_TREE"]; run = ENVIRON["GR_RUN"]; now = ENVIRON["GR_NOW"] + 0; maxage = ENVIRON["GR_MAXAGE"] + 0 }
    function hex(s) { return s ~ /^[0-9a-f]+$/ }
    function wellformed() {
      if (NF != 12 || $1 != "v1" || $2 == "" || $3 == "") return 0
      if ($4 !~ /^[0-9]+$/ || $5 !~ /^[0-9]+$/ || $8 !~ /^[0-9]+$/) return 0
      if (length($6) != 64 || !hex($6)) return 0
      if ($9 !~ /^[0-9a-f]+\+(clean|unstable|dirty-[0-9a-f]+)$/) return 0
      if ($10 == "") return 0
      if ($11 != "" && $11 !~ /^[0-9]+$/) return 0
      return 1
    }
    NF == 0 { next }
    !wellformed() { bad = 1; next }
    $9 == tree && $10 == run && ($8 + 0) <= now + 300 && now - $8 <= maxage {
      key = $2 "\t" $3
      if (key in outcome && outcome[key] != $4 "/" $11) conflict[key] = 1
      outcome[key] = $4 "/" $11; rc[key] = $4; cnt[key] = $11; id[key] = $2; cm[key] = $3
      if (!(key in order)) { order[key] = ++n; names[n] = key }
    }
    END {
      if (bad) exit
      for (i = 1; i <= n; i++) { k = names[i]; if ((k in conflict) || rc[k] != 0 || cnt[k] == "") continue; print id[k] "\t" cm[k] "\t" cnt[k] }
    }' "$RESULTS"
}

run_mode() {
  local quiet=0 want_count=0 as=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --quiet) quiet=1; shift ;;
      --count) want_count=1; shift ;;
      --as) [[ $# -ge 2 ]] || { echo "run-once: --as needs a value" >&2; exit 2; }; as="$2"; shift 2 ;;
      *) break ;;
    esac
  done
  local id="${1:-}"; shift || true
  [[ "$id" =~ ^[A-Za-z0-9_:./-]+$ ]] || { echo "run-once: bad or missing id '$id'" >&2; exit 2; }
  [[ "${1:-}" == "--" ]] || { echo "run-once: usage: run-once.sh [opts] <id> -- <command...>" >&2; exit 2; }
  shift
  (( $# > 0 )) || { echo "run-once: no command after --" >&2; exit 2; }
  local cmd="$*"; [[ -z "$as" ]] || cmd="$as"
  if [[ "$cmd" == *$'\t'* || "$cmd" == *$'\n'* ]]; then echo "run-once: a command string with a tab or newline cannot be recorded" >&2; exit 2; fi

  local tmp t0 t1 rc tree_a tree_b tree cnt="" ev osha
  tmp=$(mktemp "${TMPDIR:-/tmp}/run-once.XXXXXX") || exit 2
  tree_a=$(tree_id) || { rm -f "$tmp"; exit 2; }
  t0=$(now_ms)
  if (( quiet )); then "$@" >"$tmp" 2>&1; rc=$?; else "$@" 2>&1 | tee "$tmp"; rc=${PIPESTATUS[0]}; fi
  t1=$(now_ms)
  tree_b=$(tree_id) || tree_b="gone"
  if [[ "$tree_a" == "$tree_b" ]]; then tree="$tree_a"; else tree="${tree_a%%+*}+unstable"; fi
  (( want_count )) && { cnt=$(count_of <"$tmp") || cnt=""; }
  ev=$(clean_field "$(summary_of "$rc" <"$tmp")")
  osha=$(sha256 <"$tmp")
  mkdir -p "$(dirname "$RESULTS")" || exit 2
  printf 'v1\t%s\t%s\t%d\t%d\t%s\t%s\t%d\t%s\t%s\t%s\t%s\n' \
    "$id" "$cmd" "$rc" "$((t1 - t0))" "$osha" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(date +%s)" "$tree" "$RUN_ID" "$cnt" "$ev" >>"$RESULTS"
  if (( quiet && rc != 0 )); then tail -n 20 "$tmp"; fi
  rm -f "$tmp"
  exit "$rc"
}

case "${1:-}" in
  tree-id) tree_id ;;
  count)   count_of ;;
  summary) summary_of "${2:-0}" ;;
  resolve) [[ $# -eq 3 ]] || { echo "run-once: resolve <id> <cmd>" >&2; exit 2; }; resolve "$2" "$3" ;;
  counts)  counts ;;
  -h|--help) sed -n '2,/^set -uo/p' "${BASH_SOURCE[0]}" | sed '$d' ;;
  *)       run_mode "$@" ;;
esac
