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
# WHO RUNS THE GATES (`--run`, what `make gates`, `make selftests` and `make check-fast` call)
#
# This record used to EXECUTE every gate below, although almost all of them had already run
# earlier in the same CI job: 484 of the job's 847 seconds, spent proving what was already proven.
# The Makefile then ran each gate through scripts/run-once.sh and THIS script read the Makefile
# as text to prove the recipes were what it thought. A hand-written recogniser of a rich format
# lost that fight (an extra rule, a target-specific export, `$(eval ...)`, a GNUmakefile each forged
# an attested PASS), so the Makefile is out of the trust path. The property to keep is: AN ATTESTED
# PASS EXISTS ONLY IF THAT EXACT GATE COMMAND REALLY RAN, ON THIS TREE, IN THIS RUN, AND EXITED 0.
#
#   evidence-record.sh --run gates       every `main` gate of GATES, in order, stop at the first failure
#   evidence-record.sh --run selftests   every suite of the ONE suite list below, stop at the first failure
#   evidence-record.sh --run check-fast  the `pre` gates, then the `main` ones
#   evidence-record.sh --run <id>...     named gates, in the order given (unknown id: exit 2, nothing run)
#
# A Makefile target is one line calling this. Each gate runs as its argv through
# `scripts/run-once.sh`, which executes it in a CLEAN ENVIRONMENT and writes its one line from the
# exit status of that very execution. The set `--run gates` executes IS the GATES array and the
# set `--attest` reports IS the GATES array: nothing here is compared with anything, so nothing can
# drift. `make gates` stopped at the first failing recipe line before and still does (so do the others).
#
# TRUST MODEL (three sentences, repeated in scripts/run-once.sh). The results file protects against
# a stale line, a line of another run, a line of another tree, a dry run, and a gate renamed or
# weakened through its ENVIRONMENT (every gate runs under `env -i` with a fixed allowlist of names,
# and so does this script itself, re-executed through the same mechanism at its first line). It does
# NOT protect against a step of the same job that writes the results file by hand or edits a tracked
# script (the same power as editing any gate), nor against a changed PATH that substitutes a tool (PATH
# is trusted and passed as is; pre-existing). A Makefile edit can therefore only stop calling this
# script (no line exists, `--attest` EXECUTES everything: slow, true) or call something that forges
# lines (the same-job tampering above).
#
# ATTEST MODE (`--attest`, what `make evidence` passes)
#
# A gate is taken from the results file ONLY when a well-formed line exists for the same id, the
# same canonical argv (derived here from GATES by the shell, quoted by run-once.sh's own `canon`),
# the same tree identity (HEAD, tracked changes, untracked content), the same run id, the same
# environment-allowlist hash and the same runner hash, within the age limit, with no conflicting
# duplicate. Without EVIDENCE_RUN_ID nothing is recorded and nothing is attested: a local
# `make evidence` executes every gate. Anything else -- no file, an empty one, a malformed one,
# another HEAD, another argv, a dirtied tree, conflicting lines -- falls back to EXECUTING the gate
# here (through run-once.sh, so in the clean environment too), and the record says so. A recorded
# non-zero exit makes the record fail exactly as an executed failure does. Every gate in the record
# carries `source`: executed or attested, and an attested one names where it came from.
#
# `probe-selftests` has NO aggregate line. It is attested only when every suite of the suite list
# below has its own line of this run, and its verdict is derived from them (a failing suite line
# makes it FAIL).
#
# WHICH GATES `--run gates` DOES NOT RUN (groups `post` and `agg`): mutation-trend reads the suite
# counts the selftests recorded and would run every suite again on a laptop; ratified-invariants
# is `make verify`'s, not `make gates`'s; tcb-integrity needs the installer to have run (CI's
# install.sh step comes after check-fast); probe-selftests is derived from the suite lines. They are
# executed at attest time when no line vouches for them, as before this redesign.
#
# Usage: evidence-record.sh [--attest | --run <gates|selftests|check-fast|id>...]
# Exit: 0 every gate passed · 1 a gate failed (recorded, then reported) · 2 refused
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.." || exit 2

# CLEAN SELF. The first thing this script does is replace itself with the same script under the
# allowlisted environment (run-once.sh `clean-exec`, which also refuses a make dry run while the
# caller's MAKEFLAGS is still visible). Shell options, exported functions, GLOBIGNORE, BASHOPTS
# and the rest therefore cannot change how GATES globs expand or which suites resolve.
if [[ -z "${EVIDENCE_CLEAN_ENV:-}" ]]; then
  exec bash scripts/run-once.sh clean-exec bash scripts/evidence-record.sh "$@"
fi
unset EVIDENCE_CLEAN_ENV
# canon, summary_of, resolve_set, make_dry_run: ONE implementation, in run-once.sh (sourcing runs nothing)
# shellcheck source=run-once.sh
source scripts/run-once.sh
if make_dry_run; then
  echo "evidence-record: refusing to run or write under a make dry run / question / touch (MAKEFLAGS='${MAKEFLAGS:-}' MFLAGS='${MFLAGS:-}')" >&2
  exit 2
fi

attest=0; run_mode=0; TARGETS=()
while (( $# > 0 )); do
  case "$1" in
    --attest) attest=1 ;;
    --run) run_mode=1; shift; TARGETS=("$@"); break ;;
    *) echo "evidence-record: unknown argument '$1'" >&2; exit 2 ;;
  esac
  shift
done
if (( run_mode && attest )); then echo "evidence-record: --run and --attest are exclusive" >&2; exit 2; fi
if (( run_mode && ${#TARGETS[@]} == 0 )); then echo "evidence-record: --run needs gates, selftests, check-fast or gate ids" >&2; exit 2; fi

# The gates, each named as the dimension it answers. This list is the record's denominator AND what
# `--run` executes: a gate missing from here is a dimension nothing covers, so it is written once.
# Each entry is `id|<command as shell text>`; the text is evaluated into an argv (so a glob
# expands) and that argv is what runs. Groups (PRE_IDS, POST_IDS, AGG_IDS below the array).
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
  "gates-are-driven-template|bash _shared/probes/probe-wiring.sh prod-new/template/scripts"
  "gates-are-driven|bash _shared/probes/probe-wiring.sh"
  "gates-are-driven-scripts|bash _shared/probes/probe-wiring.sh scripts"
  "gates-are-driven-modules|bash -c 'rc=0; n=0; for d in prod-new/modules/*/scripts; do [ -d \"\$d\" ] || continue; bash _shared/probes/probe-wiring.sh \"\$d\" || rc=1; n=\$((n+1)); done; [ \"\$n\" -gt 0 ] && [ \"\$rc\" = 0 ]'"
  "db-image-pin|bash prod-new/modules/db-postgres/scripts/db-pin-check.sh prod-new/modules/db-postgres/db/image.lock --compose prod-new/modules/db-postgres/db/compose.yml prod-new/modules/db-postgres/db/compose.timescale.yml"
  "db-test-ci-wired|bash prod-new/modules/db-postgres/scripts/db-ci-wired.sh .github/workflows/pr.yaml"
  "gates-are-driven-ratified|bash _shared/probes/probe-wiring.sh verification/ratified"
  "template-version|bash scripts/template-digest.sh"
  "gap-report-consistent|bash scripts/gap-report-consistency.sh"
  "template-workflow-pins|bash scripts/template-workflow-pins.sh"
  "mutation-trend|bash scripts/mutation-baseline.sh"
  "ratified-invariants|make --no-print-directory invariants"
  "probe-selftests|make --no-print-directory selftests"
  "tcb-integrity|bash install.sh --verify"
)
# Groups, kept OUT of the entries so each entry stays `id|command` (the shape the selftests of the
# gates pin with a grep): pre = check-fast's first two; post = executed at attest time only;
# agg = probe-selftests, derived from the suite lines; every other gate is `main` (`make gates`).
PRE_IDS=(ci-workflows-valid shell-correctness)
POST_IDS=(mutation-trend ratified-invariants tcb-integrity)
AGG_IDS=(probe-selftests)
# The scripts this runner itself executes; _shared/probes/probe-wiring.sh counts them as driven while
# a Makefile or workflow calls this runner (it reads this array, comments removed).
# shellcheck disable=SC2034  # read by probe-wiring.sh, not by this script
RUNNER_HELPERS=(
  scripts/run-once.sh
)
(( ${#GATES[@]} > 0 )) || { echo "evidence-record: ZERO gates declared -- a record over nothing attests nothing" >&2; exit 2; }

# THE SUITE LIST, in ONE place: what `--run selftests` executes and what `probe-selftests` is derived
# from. Globs are expanded by the shell, in this order, then the template-only suites; a suite named
# twice runs once.
# Template selftests, by origin (checked with cmp against _shared/probes and _shared/probes/tests):
#   byte-identical MIRRORS of a _shared source, which the globs already run:
#     acceptance-audit, acceptance-coverage, acceptance-gap, check-registries, coverage-ratchet,
#     gate-run, load-rows, non-vacuity, observability-provenance, probe-self-gate,
#     sbom-ordering, single-suite-run
#   TEMPLATE-ONLY, no _shared source (the globs cannot see them):
#     changed-line-coverage, check-template-drift, probe-selftests-skip   -- run here, listed below
#     error-handling-fitness, kill-durability-state, retry   -- NOT run by this target; they run
#                                                               only in a generated repo
# The listed ones run from the framework tree so they are not first run downstream.
SUITE_GLOBS=(
  '_shared/probes/*-selftest.sh'
  '_shared/probes/tests/*-selftest.sh'
  'scripts/tests/*-selftest.sh'
  'prod-new/modules/*/scripts/tests/*-selftest.sh'
)
SUITE_TEMPLATE=(
  prod-new/template/scripts/tests/changed-line-coverage-selftest.sh
  prod-new/template/scripts/tests/check-template-drift-selftest.sh
  prod-new/template/scripts/tests/probe-selftests-skip-selftest.sh
)
# Each of these must exist AND be among the suites that ran, or the target exits 2 -- so deleting,
# renaming or un-globbing one is loud (a glob over a renamed directory reports success over nothing).
SUITE_REQUIRED=(
  _shared/probes/skills-static-selftest.sh _shared/probes/load-rows-selftest.sh
  _shared/probes/tests/probe-self-gate-selftest.sh _shared/probes/check-registries-selftest.sh
  _shared/probes/non-vacuity-selftest.sh _shared/probes/sbom-ordering-selftest.sh
  _shared/probes/agents-budget-selftest.sh _shared/probes/skill-weight-selftest.sh
  _shared/probes/prove-mutation-selftest.sh _shared/probes/acceptance-coverage-selftest.sh
)

# resolve_suites: SUITES = the resolved list. On a broken list SUITE_ERR names why (and the list is
# empty), so `--run selftests` exits 2 and attest never derives probe-selftests from it.
SUITES=(); SUITE_ERR=""
resolve_suites() {
  local w p seen=" " ran
  SUITES=(); SUITE_ERR=""
  for w in "${SUITE_TEMPLATE[@]}"; do
    [[ -f "$w" ]] || { SUITE_ERR="selftests: $w is missing: a vendored selftest nothing runs here is first exercised in someone else's CI"; return 1; }
  done
  for w in "${SUITE_REQUIRED[@]}"; do
    [[ -f "$w" ]] || { SUITE_ERR="selftests: $w is missing: it was run by name in CI and must stay"; return 1; }
  done
  for p in "${SUITE_GLOBS[@]}" "${SUITE_TEMPLATE[@]}"; do
    # shellcheck disable=SC2086  # the glob IS the point
    for w in $p; do
      [[ -f "$w" ]] || continue
      case "$seen" in *" $w "*) ;; *) SUITES+=("$w"); seen="$seen$w " ;; esac
    done
  done
  ran=" ${SUITES[*]+"${SUITES[*]}"} "
  for w in "${SUITE_REQUIRED[@]}"; do
    case "$ran" in *" $w "*) ;; *) SUITES=(); SUITE_ERR="selftests: $w exists but the glob did not run it"; return 1 ;; esac
  done
  (( ${#SUITES[@]} > 0 )) || { SUITE_ERR="selftests: found ZERO selftests -- refusing to report a pass over an empty set"; return 1; }
  return 0
}

# gate_cmd ID: the command text of the GATES entry of an id; returns 1 when there is none.
gate_cmd() {
  local e
  for e in "${GATES[@]}"; do
    [[ "${e%%|*}" == "$1" ]] && { printf '%s' "${e#*|}"; return 0; }
  done
  return 1
}
# gate_group ID: pre | post | agg | main
gate_group() {
  local x
  for x in "${PRE_IDS[@]}";  do [[ "$x" == "$1" ]] && { printf pre;  return 0; }; done
  for x in "${POST_IDS[@]}"; do [[ "$x" == "$1" ]] && { printf post; return 0; }; done
  for x in "${AGG_IDS[@]}";  do [[ "$x" == "$1" ]] && { printf agg;  return 0; }; done
  printf main
}

# gate_argv CMD: evaluate a GATES command text into the argv it stands for (ARGV). GATES is this
# script's own constant; nothing read from outside is ever evaluated.
ARGV=()
gate_argv() { eval "ARGV=($1)"; }

# ---------------------------------------------------------------------------------------------
# --run: this script executes the gates, one at a time, through run-once.sh (clean environment,
# line written from the execution's own exit status). Stop at the first failure, like make did.
# ---------------------------------------------------------------------------------------------
run_one_gate() {
  local id="$1" cmd rc
  cmd=$(gate_cmd "$id") || return 2
  gate_argv "$cmd"
  bash scripts/run-once.sh "$id" -- "${ARGV[@]}"; rc=$?
  if (( rc == 0 )); then printf '  PASS  %s\n' "$id"; else printf '  FAIL  %s (exit %d)\n' "$id" "$rc" >&2; fi
  return "$rc"
}
run_suites() {
  local t n=0 tl
  resolve_suites || { echo "$SUITE_ERR" >&2; return 2; }
  for t in "${SUITES[@]}"; do
    printf '  %-52s ' "$(basename "$t")"
    if tl=$(bash scripts/run-once.sh --quiet --count "selftest:$t" -- bash "$t"); then echo "ok"; else echo "FAIL"; printf '%s\n' "$tl"; return 1; fi
    n=$((n+1))
  done
  echo "selftests: $n passed"
}
ids_of_group() { local e; for e in "${GATES[@]}"; do [[ "$(gate_group "${e%%|*}")" == "$1" ]] && printf '%s\n' "${e%%|*}"; done; return 0; }
if (( run_mode )); then
  PLAN=()
  for a in "${TARGETS[@]}"; do
    case "$a" in
      gates)      while IFS= read -r i; do PLAN+=("gate:$i"); done < <(ids_of_group main) ;;
      check-fast) while IFS= read -r i; do PLAN+=("gate:$i"); done < <(ids_of_group pre; ids_of_group main) ;;
      selftests)  PLAN+=("suites") ;;
      *) gate_cmd "$a" >/dev/null || { echo "evidence-record: unknown gate id or target '$a'" >&2; exit 2; }; PLAN+=("gate:$a") ;;
    esac
  done
  (( ${#PLAN[@]} > 0 )) || { echo "evidence-record: nothing to run" >&2; exit 2; }
  for step in "${PLAN[@]}"; do
    if [[ "$step" == suites ]]; then run_suites; rc=$?; else run_one_gate "${step#gate:}"; rc=$?; fi
    (( rc == 0 )) || exit "$rc"
  done
  exit 0
fi

# canon_text CMD: the canonical command string (CANON) of a GATES entry, by run-once.sh's own `canon`
CANON=""
canon_text() { gate_argv "$1"; CANON=$(canon "${ARGV[@]}"); }

# attest_prepare: ONE resolve-set for everything attest mode will ask (every gate except
# probe-selftests, plus one `selftest:<suite>` want per suite): the tree identity is measured once.
# Fills RID[] / RREST[] (`kind<TAB>...` per id).
RID=(); RREST=()
attest_prepare() {
  local gt name cmd t want="" out id rest
  for gt in "${GATES[@]}"; do
    name="${gt%%|*}"; cmd="${gt#*|}"
    [[ "$(gate_group "$name")" == agg ]] && continue
    canon_text "$cmd"; want+="$name"$'\t'"$CANON"$'\n'
  done
  for t in ${SUITES[@]+"${SUITES[@]}"}; do CANON=$(canon bash "$t"); want+="selftest:$t"$'\t'"$CANON"$'\n'; done
  out=$(printf '%s' "$want" | resolve_set)
  while IFS=$'\t' read -r id rest; do
    [[ -n "$id" ]] || continue
    RID+=("$id"); RREST+=("$rest")
  done <<<"$out"
}
RESLINE=""
res_for() { local i; RESLINE=""; for (( i = 0; i < ${#RID[@]}; i++ )); do [[ "${RID[$i]}" == "$1" ]] && { RESLINE="${RREST[$i]}"; return 0; }; done; return 1; }

# attest_selftests: `probe-selftests` is never taken from an aggregate line (there is none).
# It is attested only when EVERY suite of the resolved list has its own trusted line
# of this run (same id, command `bash <suite>`, tree, run id, in time, no conflict), and its
# verdict is derived from those lines. Sets ST_RC, ST_EV, ST_N, ST_DUR, ST_UTC; on failure sets why.
attest_selftests() {
  local t kind r1 r2 r3 r4 r5 r6 failed=""
  [[ -z "$SUITE_ERR" ]] || { why="suite-list: $SUITE_ERR"; return 1; }
  (( ${#SUITES[@]} > 0 )) || { why="no-suite-list"; return 1; }
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

if (( attest )); then resolve_suites || true; attest_prepare; fi
passes=0; fails=0; n_exec=0; n_att=0
declare -a LINES=()
for gt in "${GATES[@]}"; do
  name="${gt%%|*}"; cmd="${gt#*|}"; grp=$(gate_group "$name")
  src=executed; why=""; rline=null; from=""; ev=""; rc=0
  if (( attest )); then
    if [[ "$grp" == agg ]]; then
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
    # executed through run-once.sh like every gate: the clean environment, and a line of its own
    # when a run id is set. Its output is captured here, not shown.
    gate_argv "$cmd"
    out=$(bash scripts/run-once.sh "$name" -- "${ARGV[@]}" 2>&1); rc=$?
    # the one-line evidence is cut by run-once.sh's summary_of, the same code that wrote
    # the evidence column of the results file, so both sources read alike
    ev=$(printf '%s\n' "$out" | summary_of "$rc")
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
