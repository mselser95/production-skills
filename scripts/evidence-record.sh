#!/usr/bin/env bash
# evidence-record.sh — one record per commit answering "under what standard was
# this commit held?", for the framework repo itself.
#
# WHY THIS EXISTS
#
# Dimension 11 (reproducibility) asks for a per-commit evidence record produced
# by CI on a clean tree. Every repo scaffolded from prod-new gets one, written by
# verify-standard.sh. This repo got none — verify-standard.sh is Go-only and
# refuses to run here, so the dimension arrived with its mechanism attached to a
# probe that cannot execute, and nothing filled the gap. Ephemeral CI stdout is
# not a record: ninety days later the log is gone and the question is
# unanswerable without archaeology.
#
# THE FILENAME IS AN ATTESTATION, and that rule is inherited deliberately. A
# record named <sha>.json means "measured on exactly that commit". Stamping
# `git rev-parse HEAD` onto a run measured on a DIRTY tree produces a record
# named after a commit it was never measured on, and that has already happened
# once in this org: a committed <sha>.json claimed a PASS for a probe row that
# did not exist in that commit's tree. A plausible green attestation for a state
# that never passed is worse than no record.
#
# So a dirty tree gets a name that cannot be mistaken for an attestation, and
# carries tree_clean:false.
#
# ATTEST MODE (`--attest`, what `make evidence` passes)
#
# This record used to EXECUTE every gate below, although almost all of them had
# already run earlier in the same CI job (`make check-fast`, `make selftests`):
# 484 of the job's 847 seconds, spent proving what was already proven. The property
# the repetition protected, written into the workflow next to this step, was that a
# record assembled from another step's exit codes attests to what the YAML says ran,
# not to what ran. It is kept by a different mechanism, and the property to restore
# is: AN ATTESTED PASS EXISTS ONLY IF THAT EXACT GATE COMMAND REALLY RAN, ON THIS
# TREE, IN THIS RUN, AND EXITED 0.
#
# The Makefile runs each gate through scripts/run-once.sh, which is the thing that
# executes it and writes one line, DERIVED FROM WHAT IT EXECUTED: the canonical quoting
# of the argv (printf %q of each word), the exit code, the output hash, the tree identity,
# the run id, the time. There is no caller-supplied label. In attest mode a gate is taken
# from that file ONLY when a well-formed line exists for the same id, the same canonical
# argv (re-derived here from GATES), the same tree identity (HEAD, tracked changes,
# untracked content) and the same run id, within the age limit, with no conflicting
# duplicate. Without EVIDENCE_RUN_ID nothing is recorded and nothing is attested: a local
# `make evidence` executes every gate, as before this mechanism existed.
#
# `probe-selftests` has NO aggregate line. It is attested only when every suite the
# Makefile's SELFTEST_GLOBS resolves to has its own such line of this run, and its verdict
# is derived from them (a failing suite line makes it FAIL).
#
# Anything else -- no file, an empty one, a malformed one, no run id, another HEAD,
# another argv, a dirtied tree, conflicting lines -- falls back to EXECUTING the gate here,
# as before, and the record says so. A recorded non-zero exit makes the record fail exactly
# as an executed failure does. Every gate in the record carries `source`: executed or
# attested, and an attested one names where it came from.
#
# WHAT A MAKEFILE EDIT CAN STILL DO, and what catches it. It cannot write a line, make a line
# name a command that did not run, or turn a dry run into evidence (run-once.sh refuses under
# make -n/-q/-t; the wiring check refuses $(MAKE) and `+` on recorder lines). It CAN change
# what a gate does (edit the gate script: the tree identity changes and the record is
# `dirty-`), run a gate unattested (the record then executes it), drop a gate from the
# Makefile (the GATES denominator still lists it, so the record executes it), or run the
# right argv in a neutered environment (an exported variable, make's command line): that is
# the gate's own business, and the wiring check only pins the Makefile LINE itself.
# `--check-wiring` (see below) turns every other edit of a recorder line into exit 2.
#
# Usage: evidence-record.sh [--attest] [--check-wiring]
#   --check-wiring  run the guards below and stop (exit 0 = consistent); reads text, runs nothing
# Exit: 0 every gate passed · 1 a gate failed (recorded, then reported) · 2 refused
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.." || exit 2

attest=0; check_wiring=0
for a in "$@"; do
  case "$a" in
    --attest) attest=1 ;;
    --check-wiring) check_wiring=1 ;;
    *) echo "evidence-record: unknown argument '$a'" >&2; exit 2 ;;
  esac
done

# The gates, each named as the dimension it answers. This list is the record's
# denominator: a gate missing from here is a dimension the record silently does
# not cover, so it is written once, next to the Makefile targets it mirrors.
# Each entry is `id|<command as shell text>`. The command is what run-once.sh must have
# EXECUTED for the gate to be attested: its canonical argv (printf %q of each word, after the
# shell expanded it) is compared with the one run-once.sh recorded. `probe-selftests` is
# the exception: it has no aggregate line, and is derived from the per-suite lines.
GATES=(
  "ci-workflows-valid|make --no-print-directory actionlint"
  "shell-correctness|make --no-print-directory lint"
  "skills-structural|bash _shared/probes/skills-static.sh"
  "agents-token-budget|bash _shared/probes/agents-budget.sh"
  "skill-weight|bash _shared/probes/skill-weight.sh"
  "policy-coverage|bash _shared/probes/policy-coverage.sh"
  "row-vacuity|bash _shared/probes/row-vacuity-sweep.sh"
  "row-catalogue|bash _shared/probes/row-catalogue.sh"
  "liability-registries|bash _shared/probes/check-registries.sh"
  "gate-hygiene|bash prod-new/template/scripts/gate-hygiene-fitness.sh _shared/probes prod-new/template/scripts prod-new/modules/*/scripts"
  "gates-are-driven|bash _shared/probes/probe-wiring.sh"
  "gates-are-driven-scripts|bash _shared/probes/probe-wiring.sh scripts"
  "gates-are-driven-modules|bash -c 'rc=0; n=0; for d in prod-new/modules/*/scripts; do [ -d \"\$d\" ] || continue; bash _shared/probes/probe-wiring.sh \"\$d\" || rc=1; n=\$((n+1)); done; [ \"\$n\" -gt 0 ] && [ \"\$rc\" = 0 ]'"
  "db-image-pin|bash prod-new/modules/db-postgres/scripts/db-pin-check.sh prod-new/modules/db-postgres/db/image.lock --compose prod-new/modules/db-postgres/db/compose.yml prod-new/modules/db-postgres/db/compose.timescale.yml"
  "db-test-ci-wired|bash prod-new/modules/db-postgres/scripts/db-ci-wired.sh .github/workflows/pr.yaml"
  "template-version|bash scripts/template-digest.sh"
  "mutation-trend|bash scripts/mutation-baseline.sh"
  "gap-report-consistent|bash scripts/gap-report-consistency.sh"
  "template-workflow-pins|bash scripts/template-workflow-pins.sh"
  "ratified-invariants|make --no-print-directory invariants"
  "probe-selftests|make --no-print-directory selftests"
  "tcb-integrity|bash install.sh --verify"
)
(( ${#GATES[@]} > 0 )) || { echo "evidence-record: ZERO gates declared -- a record over nothing attests nothing" >&2; exit 2; }

# ---------------------------------------------------------------------------------------
# THE WIRING CHECK reads the Makefile as TEXT. It never runs make (not even `make -n`: GNU
# make executes a recipe line holding $(MAKE) or a leading `+` under -n, which is how a dry
# run once recorded a pass), and it never evals what it reads.
#
# WHAT IT ENFORCES
#  1. COVERAGE: every script `gates:` runs appears in some GATES command (below), so the
#     record cannot report a clean total over fewer gates than the repo runs (it rotted on its
#     first day: template-digest.sh was wired and GATES held nine entries).
#  2. RECIPE GRAMMAR. `gates:` is read the way make reads it (blank lines and column-0
#     comments inside a recipe do not end it). EVERY recipe line is exactly
#         @$(RUN) <id> -- <command>
#     or one of the ALLOWED_LINES below, by exact text. `check-fast:` is held to the same
#     grammar with its own allowance. Anything else fails, naming the line: an env prefix
#     (`SKIP=1 $(RUN) ...`), a `-` or `+` prefix, `|| true`, `;`, `&&`, a pipe, a redirection,
#     a second command, a backslash continuation, a second `gates:` rule or a rule with a
#     prerequisite or target-specific variable, an unknown $(VAR). <command> may only
#     use $(PROBES) and `$$`, and must be ONE simple command outside its quotes.
#  3. NO SMUGGLED EXECUTION: no recorder line (a line holding $(RUN)) anywhere in the Makefile
#     may hold $(MAKE) / ${MAKE} or start with `+`; RUN, SHELL and PROBES are defined once, RUN
#     and SHELL to their exact text; no export/override/include/conditional/define/.ONESHELL/
#     .SHELLFLAGS/.RECIPEPREFIX/.EXPORT_ALL_VARIABLES.
#  4. DRIFT: the <command> of a `gates:`/`check-fast:` line, after $(PROBES) and `$$` are
#     resolved, is byte-equal to the GATES command of the same id. run-once.sh records the
#     canonical quoting of the argv it runs, and --attest compares that to the canonical
#     quoting of the GATES command (expanded through the shell, so a glob expands the same
#     way on both sides); equal text yields an equal argv, so a Makefile line that differs
#     would never be attested and the gate would silently run twice.
#  5. SELFTEST LIST (when the Makefile has a `selftests:` rule): the suites its SELFTEST_GLOBS
#     resolves to include every `*-selftest.sh` under the fixed selftest directories
#     (FLOOR_GLOBS), and REQUIRED_SELFTESTS are among them: dropping a suite from the glob is a
#     wiring error, not a silent narrowing.
#
# BOUNDARY. What the check pins is the Makefile line. It does NOT see the environment the
# line runs in (an exported variable in the caller, MAKEFLAGS, `make RUN=...` on the command
# line), and a gate script's behaviour under an env var is the gate's own business. What a
# Makefile edit still CAN do: change which gate runs where, run a gate unattested (then the
# record executes it itself), run it from a neutered tree, or edit the gate script (a
# changed tree, visible in the record). What it can NOT do: write a line, or make a
# line say another command ran, or make a gate that did not run exit 0, or turn a dry run
# into evidence.
# ---------------------------------------------------------------------------------------
ALLOWED_GATES_LINES=()                                                     # `gates:` allows no non-gate line
ALLOWED_CHECKFAST_LINES=('@$(MAKE) --no-print-directory gates')            # the one hop from check-fast to gates
# The directories whose `*-selftest.sh` files MUST be run by `make selftests`
FLOOR_GLOBS='_shared/probes/*-selftest.sh _shared/probes/tests/*-selftest.sh scripts/tests/*-selftest.sh prod-new/modules/*/scripts/tests/*-selftest.sh'

MK=()
if [[ -r Makefile ]]; then while IFS= read -r l || [[ -n "$l" ]]; do MK+=("$l"); done < Makefile; fi
werr=()
err() { werr+=("$1"); }

# mk_def NAME: the value of NAME's definition into MKV; fails unless there is exactly one.
mk_def() {
  local re="^$1[[:space:]]*(:|::|\\?)?=[[:space:]]*(.*)$" l n=0
  MKV=""
  for l in "${MK[@]}"; do
    if [[ "$l" =~ $re ]]; then MKV="${BASH_REMATCH[2]}"; n=$((n+1)); fi
  done
  MKV="${MKV%"${MKV##*[![:space:]]}"}"
  (( n == 1 ))
}

# mk_recipe TARGET: the recipe lines (leading tab removed) into REC. The target line must be
# exactly `TARGET:` and appear once.
mk_recipe() {
  local t="$1" line inr=0 found=0 other=0 re="^$1[[:space:]]*:"
  REC=()
  for line in "${MK[@]}"; do
    if (( inr )); then
      if [[ "$line" =~ ^[[:space:]]*$ ]]; then continue; fi
      if [[ "$line" == '#'* ]]; then continue; fi
      if [[ "$line" == $'\t'* ]]; then REC+=("${line#$'\t'}"); continue; fi
      inr=0
    fi
    if [[ "$line" == "$t:" ]]; then inr=1; found=$((found+1))
    elif [[ "$line" =~ $re ]]; then other=$((other+1)); fi
  done
  (( other == 0 )) || err "$t: a second rule or a rule with a prerequisite / target-specific variable for \`$t\` (the recipe cannot be read as one)"
  (( found == 1 )) || { (( found == 0 )) || err "$t: the target is defined $found times"; return 1; }
  return 0
}

# gate_text RAW: resolve a recipe line's command text into shell text (RT). Only $(PROBES)
# and `$$` are known make expansions.
gate_text() {
  local raw="$1" t probes
  mk_def PROBES && probes="$MKV" || probes="__PROBES_UNDEFINED__"
  t=${raw//\$\$/$'\001'}
  local rest=${t//\$\(PROBES\)/}
  if [[ "$rest" == *'$'* ]]; then RT=""; return 1; fi
  if [[ "$t" == *'$(PROBES)'* && "$probes" == "__PROBES_UNDEFINED__" ]]; then RT=""; return 1; fi
  t=${t//\$\(PROBES\)/$probes}
  RT=${t//$'\001'/\$}
  return 0
}

# single_command TEXT: true when TEXT is ONE simple command: outside single quotes there is no
# ; & | < > ( ) { } ` \ # ! and no $ (outside quotes or inside double quotes), and the quotes close.
single_command() {
  local s="$1" i c st=n n=${#1}
  for (( i = 0; i < n; i++ )); do
    c=${s:i:1}
    case "$st" in
      s) [[ "$c" == "'" ]] && st=n ;;
      d) case "$c" in
           '"') st=n ;;
           '$'|'`'|'\') return 1 ;;
         esac ;;
      n) case "$c" in
           "'") st=s ;;
           '"') st=d ;;
           ';'|'&'|'|'|'<'|'>'|'('|')'|'{'|'}'|'`'|'\'|'#'|'!'|'$') return 1 ;;
         esac ;;
    esac
  done
  [[ "$st" == n ]]
}

GATE_IDS=(); GATE_TEXTS=()      # every `@$(RUN) <id> -- <command>` line of the checked recipes, command resolved
# check_recipe TARGET ALLOWED_LINE...: apply the grammar to TARGET's recipe.
check_recipe() {
  local t="$1" line a ok rid raw gate_re='^@\$\(RUN\) ([A-Za-z0-9_:./-]+) -- (.+)$'
  shift
  mk_recipe "$t" || return 0
  for line in ${REC[@]+"${REC[@]}"}; do
    if [[ "$line" == *\\ ]]; then err "$t: recipe line ends in a backslash continuation: [$line]"; continue; fi
    [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]] && continue
    ok=0
    for a in "$@"; do [[ "$line" == "$a" ]] && ok=1; done
    (( ok )) && continue
    if [[ "$line" =~ $gate_re ]]; then
      rid="${BASH_REMATCH[1]}"; raw="${BASH_REMATCH[2]}"
      if ! gate_text "$raw"; then err "$t: [$line] uses a make expansion other than \$(PROBES) and \$\$"; continue; fi
      if ! single_command "$RT"; then err "$t: [$line] is not ONE simple command (an unquoted ; & | < > ( ) { } \` \\ # ! \$, or an unclosed quote)"; continue; fi
      GATE_IDS+=("$rid"); GATE_TEXTS+=("$RT")
    else
      err "$t: recipe line is neither '@\$(RUN) <id> -- <command>' nor an allowed line: [$line]"
    fi
  done
}

if (( ${#MK[@]} > 0 )); then
  # 1. coverage (the recipe as make reads it, not "up to the first blank line")
  uncovered=()
  if mk_recipe gates; then
    # capture, then match: `printf | grep -qF` under pipefail reads a MATCH as a miss
    # when the writer takes SIGPIPE (gate-hygiene-fitness GREPQ-UNDER-PIPEFAIL)
    gates_text=$(printf '%s\n' "${GATES[@]}")
    while IFS= read -r probe; do
      [[ -n "$probe" ]] || continue
      grep -qF "$probe" <<<"$gates_text" || uncovered+=("$probe")
    done < <(printf '%s\n' ${REC[@]+"${REC[@]}"} | grep -vE '^[[:space:]]*#' \
               | grep -oE '[A-Za-z0-9_./$()-]+\.sh' | sed 's|.*/||' | grep -vx 'run-once.sh' | sort -u)
  fi
  if (( ${#uncovered[@]} > 0 )); then
    echo "evidence-record: ${#uncovered[@]} gate(s) run by \`make gates\` are absent from this script's GATES list:" >&2
    printf '  uncovered: %s\n' "${uncovered[@]}" >&2
    echo "  The record would report a clean total while measuring less than the repo runs." >&2
    echo "  Add them to GATES, or the attestation is narrower than it looks." >&2
    exit 2
  fi
  werr=()   # the recipe was parsed once for coverage; check_recipe below reports its errors

  # 2. recipe grammar
  check_recipe gates "${ALLOWED_GATES_LINES[@]+"${ALLOWED_GATES_LINES[@]}"}"
  check_recipe check-fast "${ALLOWED_CHECKFAST_LINES[@]}"

  # 3. no smuggled execution
  run_re='\$[({]RUN[)}]'; make_re='\$[({]MAKE[)}]'; plus_re=$'^\t[@-]*\\+'
  dir_re1='^(export|unexport|override|include|-include|sinclude|vpath|define|endef|ifeq|ifneq|ifdef|ifndef|else|endif)([[:space:]]|$)'
  dir_re2='^\.(ONESHELL|SHELLFLAGS|RECIPEPREFIX|EXPORT_ALL_VARIABLES)([[:space:]:]|$)'
  runlines=0
  for line in "${MK[@]}"; do
    if [[ "$line" == $'\t'* && "$line" =~ $run_re ]]; then
      runlines=$((runlines+1))
      if [[ "$line" =~ $make_re ]]; then err "recorder line holds \$(MAKE): GNU make runs it under -n: [${line#$'\t'}]"; fi
      if [[ "$line" =~ $plus_re ]]; then err "recorder line starts with +: GNU make runs it under -n: [${line#$'\t'}]"; fi
    fi
    if [[ "$line" =~ $dir_re1 || "$line" =~ $dir_re2 ]]; then
      err "Makefile directive that can change what a recipe does: [$line]"
    fi
  done
  if (( runlines > 0 )); then
    if mk_def RUN; then [[ "$MKV" == 'bash scripts/run-once.sh' ]] || err "RUN is defined as [$MKV], not [bash scripts/run-once.sh]"; else err "RUN must be defined exactly once"; fi
  fi
  if grep -qE '^SHELL[[:space:]]*[:?]?=' Makefile; then
    if mk_def SHELL; then [[ "$MKV" == '/usr/bin/env bash' ]] || err "SHELL is defined as [$MKV], not [/usr/bin/env bash]"; else err "SHELL must be defined exactly once"; fi
  fi

  # 4. drift between the Makefile line and GATES
  drifted=()
  for i in "${!GATE_IDS[@]}"; do
    for g in "${GATES[@]}"; do
      [[ "${g%%|*}" == "${GATE_IDS[$i]}" ]] || continue
      [[ "${g#*|}" == "${GATE_TEXTS[$i]}" ]] || drifted+=("${GATE_IDS[$i]}: make gates runs [${GATE_TEXTS[$i]}], GATES holds [${g#*|}]")
    done
  done
  if (( ${#drifted[@]} > 0 )); then
    echo "evidence-record: ${#drifted[@]} gate(s) run by \`make gates\` under a different command string than GATES:" >&2
    printf '  drift: %s\n' "${drifted[@]}" >&2
    echo "  Attest would never match them: they would run twice again. Make the two strings identical." >&2
    exit 2
  fi
fi

# SUITES: the resolved selftest list (SELFTEST_GLOBS with $(PROBES) and $(TEMPLATE_SELFTESTS)
# substituted, expanded by the shell glob, no eval), and the REQUIRED ones. Text only.
SUITES=(); REQ=()
resolve_suites() {
  local probes tmpl globs req w seen=" "
  mk_def PROBES && probes="$MKV" || { err "selftests: PROBES must be defined exactly once"; return 1; }
  mk_def TEMPLATE_SELFTESTS && tmpl="$MKV" || { err "selftests: TEMPLATE_SELFTESTS must be defined exactly once"; return 1; }
  mk_def SELFTEST_GLOBS && globs="$MKV" || { err "selftests: SELFTEST_GLOBS must be defined exactly once"; return 1; }
  globs=${globs//\$\(PROBES\)/$probes}; globs=${globs//\$\(TEMPLATE_SELFTESTS\)/$tmpl}
  if [[ "$globs" == *'$'* ]]; then err "selftests: SELFTEST_GLOBS holds a make expansion other than \$(PROBES) / \$(TEMPLATE_SELFTESTS)"; return 1; fi
  for w in $globs; do
    [[ -f "$w" ]] || continue
    case "$seen" in *" $w "*) ;; *) SUITES+=("$w"); seen="$seen$w " ;; esac
  done
  if mk_def REQUIRED_SELFTESTS; then req="${MKV//\$\(PROBES\)/$probes}"; for w in $req; do REQ+=("$w"); done; fi
  return 0
}

if (( ${#MK[@]} > 0 )) && grep -qE '^selftests:' Makefile; then
  if resolve_suites; then
    seen_s=" ${SUITES[*]+"${SUITES[*]}"} "
    for w in $FLOOR_GLOBS; do
      [[ -f "$w" ]] || continue
      case "$seen_s" in *" $w "*) ;; *) err "selftests: $w is a selftest under the fixed selftest directories that SELFTEST_GLOBS does not run" ;; esac
    done
    for w in "${REQ[@]+"${REQ[@]}"}"; do
      case "$seen_s" in *" $w "*) ;; *) err "selftests: required suite $w is not among the suites SELFTEST_GLOBS resolves to" ;; esac
    done
    (( ${#SUITES[@]} > 0 )) || err "selftests: SELFTEST_GLOBS resolves to ZERO suites"
  fi
fi

if (( ${#werr[@]} > 0 )); then
  echo "evidence-record: ${#werr[@]} wiring error(s) in the Makefile:" >&2
  printf '  wiring: %s\n' "${werr[@]}" >&2
  echo "  A recorder line must be exactly the canonical form, with no prefix and no second command." >&2
  exit 2
fi
(( check_wiring == 0 )) || { echo "evidence-record: wiring consistent (${#GATES[@]} gates)"; exit 0; }

# THE CANONICAL FORM. run-once.sh records `canon` of the argv it executed: every argument through
# printf %q, joined by one space. This is the same function (the selftest pins that the two agree
# on awkward argv, so the form has one definition in effect). A GATES command is shell text: it is
# evaluated into an argv here, so a glob such as `prod-new/modules/*/scripts` expands exactly as the
# recipe's shell expanded it, and the argv is then quoted. GATES is this script's own constant;
# nothing read from the Makefile is ever evaluated.
canon_var() { local o="" a q; for a in "$@"; do printf -v q '%q' "$a"; o+="${o:+ }$q"; done; CANON=$o; }
canon_text() { eval "set -- $1"; canon_var "$@"; }

# attest_prepare: ONE call to run-once.sh for everything attest mode will ask (every gate except
# probe-selftests, plus one `selftest:<suite>` want per suite of the Makefile's resolved list):
# the tree identity is measured once. Fills RID[] / RREST[] (`kind<TAB>...` per id).
RID=(); RREST=()
attest_prepare() {
  local g name cmd t want="" out id rest
  for g in "${GATES[@]}"; do
    name="${g%%|*}"; cmd="${g#*|}"
    [[ "$name" == probe-selftests ]] && continue
    canon_text "$cmd"; want+="$name"$'\t'"$CANON"$'\n'
  done
  for t in ${SUITES[@]+"${SUITES[@]}"}; do canon_var bash "$t"; want+="selftest:$t"$'\t'"$CANON"$'\n'; done
  out=$(printf '%s' "$want" | bash scripts/run-once.sh resolve-set)
  while IFS=$'\t' read -r id rest; do
    [[ -n "$id" ]] || continue
    RID+=("$id"); RREST+=("$rest")
  done <<<"$out"
}
RESLINE=""
res_for() { local i; RESLINE=""; for (( i = 0; i < ${#RID[@]}; i++ )); do [[ "${RID[$i]}" == "$1" ]] && { RESLINE="${RREST[$i]}"; return 0; }; done; return 1; }

# attest_selftests: `probe-selftests` is never taken from an aggregate line (there is none).
# It is attested only when EVERY suite of the Makefile's resolved list has its own trusted line
# of this run (same id, command `bash <suite>`, tree, run id, in time, no conflict), and its
# verdict is derived from those lines. Sets ST_RC, ST_EV, ST_N, ST_DUR, ST_UTC; on failure sets why.
attest_selftests() {
  local t kind r1 r2 r3 r4 r5 r6 failed=""
  (( ${#SUITES[@]} > 0 )) || { why="no-suite-list-in-the-makefile"; return 1; }
  ST_DUR=0; ST_UTC=""; ST_N=0
  for t in "${SUITES[@]}"; do
    res_for "selftest:$t" || { why="suite $t: not-asked"; return 1; }
    IFS=$'\t' read -r kind r1 r2 r3 r4 r5 r6 <<<"$RESLINE"
    if [[ "$kind" != attested ]]; then why="suite $t: ${r1:-unresolved}"; return 1; fi
    [[ "$r1" == 0 ]] || failed+="${failed:+, }$t (exit $r1)"
    ST_DUR=$((ST_DUR + r3)); ST_UTC="$r5"; ST_N=$((ST_N+1))
  done
  if [[ -n "$failed" ]]; then ST_RC=1; ST_EV="failing suite(s): $failed"; else ST_RC=0; ST_EV="${ST_N} suites, each with its own passing line of this run"; fi
  return 0
}

# JSON string escaping in pure bash: no interpreter start per field (the selftest drives this
# script dozens of times). Backslash first, then the quote and the three common controls; any
# other control character becomes `?` so the output is always valid JSON.
jstr() {
  local s="$1"
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}; s=${s//$'\t'/\\t}
  s=${s//[[:cntrl:]]/?}
  printf '"%s"' "$s"
}

sha=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
# WHAT is dirty, not just THAT it is. The first version recorded a bare
# tree_clean:false, and the CI run that produced it was unactionable: the record
# said the attestation was void and gave nobody a way to find out why. Measured
# 2026-08-29 on run 33284769197 -- a fresh CI checkout produced
# dirty-d480857-*.json and there was no way to tell from the artifact what had
# touched the tree.
# .prod/evidence is EXCLUDED from the cleanliness question, and that is not a
# convenience. It is this script's own output directory: gitignored, created by
# this run, and present precisely because the record is being written. Letting it
# count means the record's existence is what voids the record -- the second
# invocation could never produce an attestation, and the first only by accident.
# Reproduced locally: with the tree otherwise clean, `git status --porcelain`
# returned exactly `?? .prod/evidence/`.
#
# .evidence is the same kind of thing: the results file run-once.sh appends to.
#
# Everything else still counts, and is NAMED in the record: a bare
# tree_clean:false says the attestation is void and gives nobody a way to find
# out why. Measured 2026-08-29 on CI run 33284769197, whose artifact was
# dirty-d480857-*.json from a fresh checkout with no way to tell what touched it.
dirty_paths=$(git status --porcelain 2>/dev/null | grep -vE '^\?\? (\.prod/evidence|\.evidence)/?$' | head -20)
if [[ -n "$dirty_paths" ]]; then
  tree_clean=false
  record=".prod/evidence/dirty-${sha}-$(date -u +%Y%m%dT%H%M%SZ).json"
else
  tree_clean=true
  record=".prod/evidence/$sha.json"
fi
mkdir -p .prod/evidence || exit 2

(( attest == 0 )) || attest_prepare
passes=0; fails=0; n_exec=0; n_att=0
declare -a LINES=()
for g in "${GATES[@]}"; do
  name="${g%%|*}"; cmd="${g#*|}"
  src=executed; why=""; rline=null; from=""; ev=""; rc=0
  if (( attest )); then
    if [[ "$name" == probe-selftests ]]; then
      ST_RC=0; ST_EV=""
      if attest_selftests; then
        src=attested; rc=$ST_RC; ev=$ST_EV
        from=$(printf '{ "results_file": %s, "derived_from_suites": %s, "duration_ms": %s, "recorded_utc": "%s" }' \
          "$(jstr "${EVIDENCE_RESULTS:-.evidence/results.tsv}")" "$ST_N" "$ST_DUR" "$ST_UTC")
      else
        why="${why:-unresolved}"
      fi
    else
      res_for "$name" || RESLINE="miss"$'\t'"not-asked"
      IFS=$'\t' read -r kind r1 r2 r3 r4 r5 r6 <<<"$RESLINE"
      if [[ "$kind" == attested ]]; then
        src=attested; rc=$r1; rline=$r2; ev=$r6
        from=$(printf '{ "results_file": %s, "line": %s, "duration_ms": %s, "output_sha256": "%s", "recorded_utc": "%s" }' \
          "$(jstr "${EVIDENCE_RESULTS:-.evidence/results.tsv}")" "$r2" "$r3" "$r4" "$r5")
      else
        why="${r1:-unresolved}"
      fi
    fi
  fi
  if [[ "$src" == executed ]]; then
    out=$(eval "$cmd" 2>&1); rc=$?
    # the one-line evidence is cut by run-once.sh's summary, the same code that wrote
    # the evidence column of the results file, so both sources read alike
    ev=$(printf '%s\n' "$out" | bash scripts/run-once.sh summary "$rc")
    n_exec=$((n_exec+1))
  else
    n_att=$((n_att+1))
  fi
  if (( rc == 0 )); then verdict=PASS; passes=$((passes+1)); else verdict=FAIL; fails=$((fails+1)); fi
  printf '  %-24s %-4s %-8s %s\n' "$name" "$verdict" "$src" "${ev:0:84}"
  extra=""
  [[ -z "$from" ]] || extra=", \"attested_from\": $from"
  [[ -z "$why" ]] || extra="$extra, \"why_executed\": $(jstr "$why")"
  LINES+=("    { \"gate\": $(jstr "$name"), \"command\": $(jstr "$cmd"), \"verdict\": \"$verdict\", \"source\": \"$src\", \"results_line\": $rline, \"evidence\": $(jstr "$ev")${extra} }")
done

{
  printf '{\n  "commit": "%s",\n' "$sha"
  printf '  "tree_clean": %s,\n' "$tree_clean"
  printf '  "dirty_paths": %s,\n' "$(jstr "$dirty_paths")"
  printf '  "generated_utc": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '  "spec": "production.yaml",\n'
  printf '  "tier": "%s",\n' "$(grep -m1 -E '^[[:space:]]*tier:' production.yaml 2>/dev/null | tr -d ' ' | cut -d: -f2)"
  printf '  "toolchain_note": "verify-standard.sh is Go-only and refuses to run in this repo; these gates are its equivalent here",\n'
  printf '  "attest_mode": %s,\n' "$([[ $attest == 1 ]] && echo true || echo false)"
  printf '  "totals": { "pass": %d, "fail": %d, "executed": %d, "attested": %d },\n' "$passes" "$fails" "$n_exec" "$n_att"
  printf '  "gates": [\n'
  first=1
  for l in "${LINES[@]}"; do [[ $first -eq 1 ]] || printf ',\n'; first=0; printf '%s' "$l"; done
  printf '\n  ]\n}\n'
} > "$record"

echo "evidence record: $record"
[[ "$tree_clean" == true ]] || echo "  (working tree DIRTY: this record is NOT an attestation for commit $sha)"
(( fails == 0 )) || { echo "VERDICT: INCOMPLETE -- $fails gate(s) failed; each is a finding, not a reason to soften the gate." >&2; exit 1; }
echo "VERDICT: COMPLETE -- ${passes}/${#GATES[@]} gates passed (${n_att} attested, ${n_exec} executed)"
