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
# THE PROPERTY THAT MUST SURVIVE: an attested PASS exists only if that exact gate
# command really ran, on this tree, in this run, and exited 0. The record used to
# EXECUTE every gate itself, so it was true by construction; this file keeps it by
# making the one who EXECUTES a gate the one who writes its line:
#
#   * WHAT IS RECORDED IS DERIVED FROM WHAT IS EXECUTED, never supplied beside it.
#     The command column is the exact argv this script runs, each argument quoted
#     with `printf %q` and joined by single spaces (`canon`). There is no `--as`
#     label: a label is a claim, and nothing compared it to what ran.
#   * NOTHING IS RECORDED WITHOUT AN EXPLICIT RUN ID. With EVIDENCE_RUN_ID unset
#     (a developer machine, a pre-commit hook) the command still runs and its exit
#     code is returned, but no line is written and nothing can be attested, so a stale
#     local line can never vouch for anything and the file never grows. CI sets the id
#     per job attempt.
#   * NOTHING IS RUN OR RECORDED UNDER `make -n`, `-q` or `-t`: GNU make still
#     executes a recipe line containing $(MAKE) (or starting with `+`) in those modes,
#     so a wrapped dry-run `make` exited 0 and was recorded as a pass. The flags are
#     read from MAKEFLAGS and MFLAGS (the grouped first word `nw -- VAR=x`, `-n`, and
#     the long forms) and the call exits 2 with one line, writing nothing.
#   * The line carries the tree identity measured before AND after the command, the
#     run id and the time. A reader (`resolve`) trusts a line only when every field is
#     strictly well-formed and every one matches what it is about to claim.
#
# RESULTS FILE: ${EVIDENCE_RESULTS:-.evidence/results.tsv}, one TSV line per run,
# twelve columns, no header:
#   v2 | id | command | exit | duration_ms | output_sha256 | utc | epoch | tree | run | count | evidence
# `command` is `canon` of the argv (for `bash -c '<loop>'` that is `bash -c <the loop,
# quoted>`). `tree` is `<HEAD>+clean`, `<HEAD>+dirty-<sha256>` or `<HEAD>+unstable` (the
# command changed the tree while it ran: never attestable). `run` is $EVIDENCE_RUN_ID.
# `count` is the suite's own case count (only with --count). Keep the file under
# .evidence/ or outside the tree: a results file inside the tree is itself a change to it.
#
# WHEN A LINE IS WRITTEN, AND WHEN IT CAN BE ATTESTED
#   CI (run id set)                    written; attestable in the same run, same tree, <= MAX_AGE
#   local, EVIDENCE_RUN_ID set         written; attestable the same way
#   local, no run id                   runs the command, writes NOTHING, nothing attestable
#   under make -n / -q / -t            refused (exit 2): not run, not written
#
# TREE IDENTITY, and its boundary. HEAD plus tracked changes (`git diff HEAD --binary`,
# no textconv, no external diff) plus the CONTENT of untracked-not-ignored files, with
# the user's and the system's git config neutralised. It does NOT cover git-IGNORED
# files, the repo-local `.git/config`, or anything outside the work tree: a gate that
# reads an ignored file can change its verdict under an unchanged identity. That is not
# knowable from here; the age limit and the per-run id are the second guard.
#
# Usage:
#   run-once.sh [--quiet] [--count] <id> -- <command...>
#       runs once; exit code = the command's. --quiet prints nothing on success and the
#       last 20 lines on failure.
#   run-once.sh canon <arg...>     print the canonical command string of an argv
#   run-once.sh tree-id            print the tree identity
#   run-once.sh count              stdin -> the suite's case count (exit 1 if none)
#   run-once.sh summary <rc>       stdin -> the one-line evidence of a gate's output
#   run-once.sh resolve <id> <cmd> print `attested<TAB>...` or `miss<TAB><reason>`
#   run-once.sh resolve-set        stdin `id<TAB>cmd` lines -> one `id<TAB>attested|miss...` line each
#   run-once.sh counts             print `<id><TAB><command><TAB><count>` for every trusted passing line
# Exit: the command's own (run) · 0 ok (others) · 1 nothing to report · 2 refused
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.." || exit 2

RESULTS="${EVIDENCE_RESULTS:-.evidence/results.tsv}"
# No default: an unset id disables recording and attestation (see the header).
RUN_ID="${EVIDENCE_RUN_ID:-}"
# a line older than this is not "this run" on a developer machine, where the file
# outlives the run that wrote it. CI never gets near it. A second guard after the run id.
MAX_AGE="${EVIDENCE_MAX_AGE:-3600}"

# The canonical command string: every argument through printf %q, joined by one space.
# printf -v, not $(printf ...): no fork per argument.
canon() { local o="" a q; for a in "$@"; do printf -v q '%q' "$a"; o+="${o:+ }$q"; done; printf '%s' "$o"; }

# True when make was started with -n / -q / -t (or their long forms). MAKEFLAGS holds the
# single-letter flags grouped in its FIRST word WITHOUT a dash (`nw -- VAR=x`); MFLAGS holds
# them dashed. Words after a bare `--` are variable assignments. Globbing is off while the
# words are split.
make_dry_run() {
  local v w first
  set -f
  for v in "${MAKEFLAGS:-}" "${MFLAGS:-}"; do
    first=1
    for w in $v; do
      case "$w" in
        --) break ;;
        --dry-run|--just-print|--recon|--question|--touch) set +f; return 0 ;;
        --*|*=*) ;;
        -*) if [[ "${w#-}" =~ ^[A-Za-z]+$ && "${w#-}" == *[nqt]* ]]; then set +f; return 0; fi ;;
        *) if (( first )) && [[ "$w" =~ ^[A-Za-z]+$ && "$w" == *[nqt]* ]]; then set +f; return 0; fi ;;
      esac
      first=0
    done
  done
  set +f
  return 1
}

sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi; }

now_ms() { if [[ -n "${EPOCHREALTIME:-}" ]]; then local t=${EPOCHREALTIME/[.,]/}; echo "${t:0:13}"; else echo "$(date +%s)000"; fi; }

# git with the user's and the system's configuration neutralised: a textconv or an external
# diff driver in ~/.gitconfig must not decide what "the tree" is.
g() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME=/dev/null/none git "$@"; }

# The tree identity. .prod/evidence and .evidence are this tooling's own output
# directories, so their existence must not be what makes the tree dirty.
tree_id() {
  local head st untracked h
  head=$(g rev-parse HEAD 2>/dev/null) || { echo "run-once: not a git work tree with a HEAD" >&2; return 1; }
  st=$(g status --porcelain --untracked-files=normal 2>/dev/null | grep -vE '^\?\? (\.prod/evidence|\.evidence)/?$' || true)
  if [[ -z "$st" ]]; then echo "${head}+clean"; return 0; fi
  untracked=$(g ls-files -o --exclude-standard 2>/dev/null | grep -vE '^(\.prod/evidence|\.evidence)/' || true)
  h=$({ printf '%s\n' "$st"; g diff HEAD --no-ext-diff --no-textconv --binary 2>/dev/null
        if [[ -n "$untracked" ]]; then printf '%s\n' "$untracked" | g hash-object --no-filters --stdin-paths 2>/dev/null; fi
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

# The awk every reader shares: ONE strict definition of a well-formed line. Hand-written
# lines are the attack, so nothing is accepted by leniency: the exit code is 0 or 1..999 with
# no leading zero (`00` is not a pass), the epoch and the hash have fixed shapes, the id and
# the run id come from a fixed charset, exactly twelve columns, no CR. No `{n}` intervals:
# the macOS awk does not implement them.
AWK_WF='
function wellformed(   n, tp, hd, tl) {
  if (NF != 12 || $1 != "v2") return 0
  if (index($0, "\r") > 0) return 0
  if ($2 !~ "^[A-Za-z0-9_:./-]+$") return 0
  if ($3 == "") return 0
  if ($4 !~ /^(0|[1-9][0-9]?[0-9]?)$/) return 0
  if ($5 !~ /^[0-9]+$/) return 0
  if (length($6) != 64 || $6 !~ /^[0-9a-f]+$/) return 0
  if ($7 !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$/) return 0
  if ($8 !~ /^[1-9][0-9]*$/ || length($8) < 9 || length($8) > 12) return 0
  n = split($9, tp, "+"); if (n != 2) return 0
  hd = tp[1]; tl = tp[2]
  if ((length(hd) != 40 && length(hd) != 64) || hd !~ /^[0-9a-f]+$/) return 0
  if (tl != "clean" && tl != "unstable") {
    if (substr(tl, 1, 6) != "dirty-" || length(tl) != 70 || substr(tl, 7) !~ /^[0-9a-f]+$/) return 0
  }
  if ($10 !~ "^[A-Za-z0-9_.:-]+$") return 0
  if ($11 != "" && $11 !~ /^(0|[1-9][0-9]*)$/) return 0
  return 1
}'

# resolve_core <want-file> <prefix 0|1>: for every `id<TAB>command` in the want file decide
# whether the results file holds a line this run may attest to. Never prints `attested`
# unless exactly the same id, command string, tree identity and run id are on a well-formed
# line within MAX_AGE, and every such line agrees on the exit code. A line dated more than
# 300 s in the future, or any malformed line, voids the WHOLE file.
resolve_core() {
  local want="$1" prefix="$2" tree
  [[ -e "$RESULTS" ]] || { awk -F'\t' -v p="$prefix" '{ printf "%smiss\tno-results-file\n", (p ? $1 "\t" : "") }' "$want"; return 0; }
  [[ -s "$RESULTS" ]] || { awk -F'\t' -v p="$prefix" '{ printf "%smiss\tempty-results-file\n", (p ? $1 "\t" : "") }' "$want"; return 0; }
  tree=$(tree_id) || { awk -F'\t' -v p="$prefix" '{ printf "%smiss\tno-tree-identity\n", (p ? $1 "\t" : "") }' "$want"; return 0; }
  # values go through ENVIRON, not -v: awk -v interprets backslash escapes in them
  GR_WANT="$want" GR_PREFIX="$prefix" GR_TREE="$tree" GR_RUN="$RUN_ID" GR_NOW="$(date +%s)" GR_MAXAGE="$MAX_AGE" awk -F'\t' "$AWK_WF"'
    BEGIN {
      tree = ENVIRON["GR_TREE"]; run = ENVIRON["GR_RUN"]; now = ENVIRON["GR_NOW"] + 0; maxage = ENVIRON["GR_MAXAGE"] + 0
      pre = ENVIRON["GR_PREFIX"] + 0
      while ((getline l < ENVIRON["GR_WANT"]) > 0) { split(l, w, "\t"); nw++; wid[nw] = w[1]; key[w[1] "\t" w[2]] = nw }
    }
    NF == 0 { next }
    { seen++ }
    !wellformed() { bad = NR; next }
    ($8 + 0) > now + 300 { bad = NR; future = 1; next }
    { k = $2 "\t" $3 }
    (k in key) && $9 == tree && $10 == run && now - $8 <= maxage {
      i = key[k]
      if (matched[i] && $4 != rc0[i]) conflict[i] = 1
      if (!matched[i]) rc0[i] = $4
      matched[i]++; line[i] = NR; rc[i] = $4; dur[i] = $5; sha[i] = $6; utc[i] = $7; ev[i] = $12
    }
    END {
      for (i = 1; i <= nw; i++) {
        p = pre ? wid[i] "\t" : ""
        if (bad)             { printf "%smiss\tmalformed-results-file (line %d%s)\n", p, bad, (future ? ", future-dated" : ""); continue }
        if (!seen)           { printf "%smiss\tempty-results-file\n", p; continue }
        if (!matched[i])     { printf "%smiss\tno-line-for-this-id-command-tree-run\n", p; continue }
        if (conflict[i])     { printf "%smiss\tconflicting-lines-for-this-id\n", p; continue }
        printf "%sattested\t%s\t%d\t%s\t%s\t%s\t%s\n", p, rc[i], line[i], dur[i], sha[i], utc[i], ev[i]
      }
    }' "$RESULTS"
}

# resolve <id> <canonical command>. No run id -> nothing is ever attested.
resolve() {
  [[ -n "$RUN_ID" ]] || { printf 'miss\tno-run-id\n'; return 0; }
  local w; w=$(mktemp "${TMPDIR:-/tmp}/run-once-want.XXXXXX") || return 2
  printf '%s\t%s\n' "$1" "$2" >"$w"
  resolve_core "$w" 0
  rm -f "$w"
}

# resolve-set: stdin `id<TAB>command` lines, one `id<TAB>attested|miss...` line back for each,
# the tree identity measured once.
resolve_set() {
  local w; w=$(mktemp "${TMPDIR:-/tmp}/run-once-want.XXXXXX") || return 2
  cat >"$w"
  if [[ -z "$RUN_ID" ]]; then awk -F'\t' '{ printf "%s\tmiss\tno-run-id\n", $1 }' "$w"; else resolve_core "$w" 1; fi
  rm -f "$w"
}

# counts: `<id><TAB><command><TAB><count>` for each id with exactly one outcome across its trusted
# lines, a zero exit, and a count. A malformed file, or no run id, yields nothing.
counts() {
  [[ -s "$RESULTS" && -n "$RUN_ID" ]] || return 0
  local tree; tree=$(tree_id) || return 0
  GR_TREE="$tree" GR_RUN="$RUN_ID" GR_NOW="$(date +%s)" GR_MAXAGE="$MAX_AGE" awk -F'\t' "$AWK_WF"'
    BEGIN { tree = ENVIRON["GR_TREE"]; run = ENVIRON["GR_RUN"]; now = ENVIRON["GR_NOW"] + 0; maxage = ENVIRON["GR_MAXAGE"] + 0 }
    NF == 0 { next }
    !wellformed() { bad = 1; next }
    ($8 + 0) > now + 300 { bad = 1; next }
    $9 == tree && $10 == run && now - $8 <= maxage {
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
  local quiet=0 want_count=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --quiet) quiet=1; shift ;;
      --count) want_count=1; shift ;;
      --as) echo "run-once: --as is gone: the recorded command is always the argv that runs" >&2; exit 2 ;;
      *) break ;;
    esac
  done
  local id="${1:-}"; shift || true
  [[ "$id" =~ ^[A-Za-z0-9_:./-]+$ && "$id" != -* ]] || { echo "run-once: bad or missing id '$id'" >&2; exit 2; }
  [[ "${1:-}" == "--" ]] || { echo "run-once: usage: run-once.sh [opts] <id> -- <command...>" >&2; exit 2; }
  shift
  (( $# > 0 )) || { echo "run-once: no command after --" >&2; exit 2; }
  if make_dry_run; then
    echo "run-once: refusing to run or record '$id' under a make dry run / question / touch (MAKEFLAGS='${MAKEFLAGS:-}' MFLAGS='${MFLAGS:-}')" >&2
    exit 2
  fi
  local record=0
  if [[ -n "$RUN_ID" ]]; then
    [[ "$RUN_ID" =~ ^[A-Za-z0-9_.:-]+$ ]] || { echo "run-once: EVIDENCE_RUN_ID has characters outside [A-Za-z0-9_.:-]" >&2; exit 2; }
    record=1
  fi
  local cmd; cmd=$(canon "$@")

  local tmp t0 t1 rc tree_a="" tree_b tree cnt="" ev osha
  tmp=$(mktemp "${TMPDIR:-/tmp}/run-once.XXXXXX") || exit 2
  if (( record )); then tree_a=$(tree_id) || { rm -f "$tmp"; exit 2; }; fi
  t0=$(now_ms)
  if (( quiet )); then "$@" >"$tmp" 2>&1; rc=$?; else "$@" 2>&1 | tee "$tmp"; rc=${PIPESTATUS[0]}; fi
  t1=$(now_ms)
  if (( record )); then
    tree_b=$(tree_id) || tree_b="gone"
    if [[ "$tree_a" == "$tree_b" ]]; then tree="$tree_a"; else tree="${tree_a%%+*}+unstable"; fi
    (( want_count )) && { cnt=$(count_of <"$tmp") || cnt=""; }
    ev=$(clean_field "$(summary_of "$rc" <"$tmp")")
    osha=$(sha256 <"$tmp")
    mkdir -p "$(dirname "$RESULTS")" || exit 2
    printf 'v2\t%s\t%s\t%d\t%d\t%s\t%s\t%d\t%s\t%s\t%s\t%s\n' \
      "$id" "$cmd" "$rc" "$((t1 - t0))" "$osha" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(date +%s)" "$tree" "$RUN_ID" "$cnt" "$ev" >>"$RESULTS"
  fi
  if (( quiet && rc != 0 )); then tail -n 20 "$tmp"; fi
  rm -f "$tmp"
  exit "$rc"
}

case "${1:-}" in
  canon)   shift; canon "$@" ;;
  tree-id) tree_id ;;
  count)   count_of ;;
  summary) summary_of "${2:-0}" ;;
  resolve) [[ $# -eq 3 ]] || { echo "run-once: resolve <id> <cmd>" >&2; exit 2; }; resolve "$2" "$3" ;;
  resolve-set) resolve_set ;;
  counts)  counts ;;
  -h|--help) sed -n '2,/^set -uo/p' "${BASH_SOURCE[0]}" | sed '$d' ;;
  *)       run_mode "$@" ;;
esac
