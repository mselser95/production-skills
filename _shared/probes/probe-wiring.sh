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

# THE RUNNER AS A SURFACE. `make gates` / `make selftests` / `make check-fast` are one line each
# calling scripts/evidence-record.sh, which owns the gate list (GATES) and the suite list
# (SUITE_*). The Makefile therefore no longer NAMES the scripts, the runner does. Its lists count
# as invocations under two conditions, so this is not a loophole:
#  (a) only for what a surface (Makefile / workflow / hook, comments stripped) really drives:
#      `evidence-record.sh --run gates` drives the `main` gates, `--run check-fast` the `pre` and
#      `main` ones, `--run selftests` the suite lists, `--run <id>` that gate, `--attest` every gate
#      (it executes the ones no line vouches for). If nothing drives the runner, its lists drive
#      nothing and every script named only there is an orphan.
#  (b) only GATES entries (`"id|command"`), the SUITE_* and RUNNER_HELPERS array bodies count, read with comment
#      lines removed: a script named in a runner comment, a header or another string is not wired.
RUNNER=scripts/evidence-record.sh
if [[ -f "$RUNNER" ]]; then
  driven=$(grep -oE 'evidence-record\.sh[[:space:]]+(--run[[:space:]]+[A-Za-z0-9_ -]*|--attest)' <<<"$haystack" || true)
  if [[ -n "$driven" ]]; then
    runner_src=$(grep -v '^[[:space:]]*#' "$RUNNER" || true)
    ids_in() { sed -n -E "s/^$1=\\((.*)\\)[[:space:]]*\$/\\1/p" <<<"$runner_src"; }
    array_body() { sed -n "/^$1=(/,/^)/p" <<<"$runner_src" | sed '1d;$d'; }
    gate_ids=(); gate_cmds=()
    entry_re='"([A-Za-z0-9_-]+)\|(.*)"[[:space:]]*$'   # not anchored at the line start: the comment stripping above is what keeps `# "id|cmd"` out
    while IFS= read -r l; do
      if [[ "$l" =~ $entry_re ]]; then gate_ids+=("${BASH_REMATCH[1]}"); gate_cmds+=("${BASH_REMATCH[2]}"); fi
    done < <(array_body GATES)
    pre=" $(ids_in PRE_IDS) "; post=" $(ids_in POST_IDS) "; agg=" $(ids_in AGG_IDS) "
    want_main=0; want_pre=0; want_suites=0; want_all=0; want_ids=" "
    for w in $driven; do
      case "$w" in
        gates) want_main=1 ;;
        check-fast) want_main=1; want_pre=1 ;;
        selftests) want_suites=1 ;;
        --attest) want_all=1 ;;
        evidence-record.sh|--run) ;;
        *) want_ids="$want_ids$w " ;;
      esac
    done
    runner_text=""
    for i in "${!gate_ids[@]}"; do
      id="${gate_ids[$i]}"; take=0
      if (( want_all )); then take=1
      elif [[ "$want_ids" == *" $id "* ]]; then take=1
      elif [[ "$pre" == *" $id "* ]]; then (( want_pre )) && take=1
      elif [[ "$post" == *" $id "* || "$agg" == *" $id "* ]]; then :
      else (( want_main )) && take=1
      fi
      (( take )) && runner_text+="${gate_cmds[$i]}"$'\n'
    done
    # RUNNER_HELPERS: the scripts the runner itself executes (run-once.sh), driven whenever it is
    runner_text+="$(array_body RUNNER_HELPERS)"$'\n'
    if (( want_suites )); then
      for a in SUITE_GLOBS SUITE_TEMPLATE SUITE_REQUIRED; do runner_text+="$(array_body "$a")"$'\n'; done
    fi
    haystack+=$'\n'"$runner_text"
  fi
fi

mapfile -t PROBES < <(find "$PROBE_DIR" -name '*.sh' -type f | sort)
if (( ${#PROBES[@]} == 0 )); then
  echo "probe-wiring: found ZERO probes in $PROBE_DIR -- a clean result over nothing is not a clean result" >&2
  exit 2
fi

# DECLARED EXCEPTIONS: probes this repo ships and deliberately does not run.
# Each carries its reason -- the reason this list exists rather than
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
  [prod-new/template/scripts/changed-line-coverage.sh]="executed in scaffolded repos by the template Makefile or its workflows; edited here, not run here"
  [prod-new/template/scripts/check-template-drift.sh]="executed in scaffolded repos by the template Makefile or its workflows; edited here, not run here"
  [prod-new/template/scripts/acceptance-coverage.sh]="executed in scaffolded repos by the template Makefile ('make acceptance', inside check-fast); edited here, not run here"
  [prod-new/template/scripts/acceptance-gap.sh]="agent tool, run by the orchestrator in scaffolded repos on supplied result files (not by the Makefile: the gap needs results only the orchestrator has); edited here, not run here"
  [prod-new/template/scripts/coverage.sh]="executed in scaffolded repos by the template Makefile or its workflows; edited here, not run here"
  [prod-new/template/scripts/error-handling-fitness.sh]="executed in scaffolded repos by the template Makefile or its workflows; edited here, not run here"
  [prod-new/template/scripts/kill-durability.sh]="executed in scaffolded repos by the template Makefile or its workflows; edited here, not run here"
  [prod-new/template/scripts/no-unfilled-slots.sh]="executed in scaffolded repos by the template Makefile or its workflows; edited here, not run here"
  [prod-new/template/scripts/retry.sh]="executed in scaffolded repos by the template Makefile or its workflows; edited here, not run here"
  [prod-new/template/scripts/verify-standard.sh]="executed in scaffolded repos by the template Makefile or its workflows; edited here, not run here"
  # Added 2026-10-02. Not a gate: an agent TOOL the prod-implementer runs in
  # the target repo (prod-implement/references/probes/), so it has no Makefile
  # invoker here. Its verdicts are proven by prove-mutation-selftest.sh, which
  # `make selftests` runs via the *-selftest.sh glob.
  [prod-new/modules/db-postgres/scripts/db-pin-verify-live.sh]="opt-in verifier, needs Docker and the images (the offline gate is db-pin-check.sh); a human runs it when bumping the image pair (README); proven by db-pin-verify-live-selftest.sh with a fake docker"
  [prod-new/modules/monorepo-root/scripts/monorepo-run.sh]="the root Makefile of a GENERATED monorepo invokes it (check-fast, verify and test delegate through it); this repo is not a monorepo; proven here by monorepo-root-selftest.sh on an assembled tree (a unit missing a mandatory target: no unit target is run; The inspection asks make -C <unit> -q <target>; only if that answers 0 does it ask make -C <unit> -q -B <target> (the same question with every file considered out of date, so the verdict does not depend on whether the unit's outputs are fresh, and with the unit's makefile named by -f and a module-owned makefile read after it that gives every makefile make has read an empty recipe, so that no makefile is remade: GNU make 3.81 remakes an included makefile that has a rule under -B and answers 1 for it, 4.3 does not); only if the last question asked answered 2 does it ask make -C <unit> -n <target> (exit status only; output discarded). Verdict: -q 1 = present; -q 0 and -q -B 1 = present (the target was only up to date), unless a file or directory named like the target sits beside the Makefile and the rule is not .PHONY (the real run says up to date: idle, with a .PHONY hint); -q -B 0 = idle (nothing to run even with everything out of date); an answer of 2 asks -n: 0 = present, 2 = missing. First question: make parses the unit's Makefile (a parse-time \$(shell ...) runs; an included file that has a rule may be remade, its recipe IN FULL, plain lines too). Under -q make executes the recipe lines marked + or containing \$(MAKE) of the target and of its prerequisites, each recipe at most up to its first line that is neither (an upper bound: it stops at the first out-of-date prerequisite whose recipe starts with a plain line; a file target that a + line just created may be deleted again). The -B question executes the same classes of lines, passed on to sub-makes in question mode as well, but MORE of them, since nothing counts as up to date: the + / \$(MAKE) lines of prerequisites and sub-make targets that were up to date run too, and an included makefile is not remade (the pin). Under -n make walks the WHOLE recipe, so every + / \$(MAKE) line of the target and of all its out-of-date prerequisites runs (a sub-make in dry-run mode runs its + lines and not its plain lines). Apart from that remake under the first question and -n, no plain recipe line runs under any question; the pin makefile runs nothing. On GNU make 3.81 and 4.3 the judgment is the same, and the same before and after a real run, for every shape measured (an included makefile that has a rule, with no rule that runs anything for the target, is idle, and so is verify: gen.mk with gen.mk such an included makefile; the same unit with verify: build or a \$(MAKE) build line is present), except a recipe made only of + / \$(MAKE) lines that run nothing (verify: with +true, +@echo ok, or \$(MAKE) check-fast with check-fast: ;): 3.81 answers 1 to -q (present), 4.3 answers 0 to -q and to -q -B (idle, fail-closed: such a recipe verifies nothing); verify: +false differs too (3.81: -q 2 and -n 2 = missing; 4.3: -q 1 = present) and on both the root make verify ends non-zero. What runs during the inspection was measured on GNU make 3.81 and 4.3)"
  [prod-new/modules/monorepo-root/scripts/monorepo-settings-check.sh]="gate of a GENERATED monorepo (catalog-only versions, one lockfile, repo.yaml inventory); the root Makefile runs it first in check-fast and verify (settings-check prerequisite); The inspection asks make -C <unit> -q <target>; only if that answers 0 does it ask make -C <unit> -q -B <target> (the same question with every file considered out of date, so the verdict does not depend on whether the unit's outputs are fresh, and with the unit's makefile named by -f and a module-owned makefile read after it that gives every makefile make has read an empty recipe, so that no makefile is remade: GNU make 3.81 remakes an included makefile that has a rule under -B and answers 1 for it, 4.3 does not); only if the last question asked answered 2 does it ask make -C <unit> -n <target> (exit status only; output discarded). Verdict: -q 1 = present; -q 0 and -q -B 1 = present (the target was only up to date), unless a file or directory named like the target sits beside the Makefile and the rule is not .PHONY (the real run says up to date: idle, with a .PHONY hint); -q -B 0 = idle (nothing to run even with everything out of date); an answer of 2 asks -n: 0 = present, 2 = missing. First question: make parses the unit's Makefile (a parse-time \$(shell ...) runs; an included file that has a rule may be remade, its recipe IN FULL, plain lines too). Under -q make executes the recipe lines marked + or containing \$(MAKE) of the target and of its prerequisites, each recipe at most up to its first line that is neither (an upper bound: it stops at the first out-of-date prerequisite whose recipe starts with a plain line; a file target that a + line just created may be deleted again). The -B question executes the same classes of lines, passed on to sub-makes in question mode as well, but MORE of them, since nothing counts as up to date: the + / \$(MAKE) lines of prerequisites and sub-make targets that were up to date run too, and an included makefile is not remade (the pin). Under -n make walks the WHOLE recipe, so every + / \$(MAKE) line of the target and of all its out-of-date prerequisites runs (a sub-make in dry-run mode runs its + lines and not its plain lines). Apart from that remake under the first question and -n, no plain recipe line runs under any question; the pin makefile runs nothing. On GNU make 3.81 and 4.3 the judgment is the same, and the same before and after a real run, for every shape measured (an included makefile that has a rule, with no rule that runs anything for the target, is idle, and so is verify: gen.mk with gen.mk such an included makefile; the same unit with verify: build or a \$(MAKE) build line is present), except a recipe made only of + / \$(MAKE) lines that run nothing (verify: with +true, +@echo ok, or \$(MAKE) check-fast with check-fast: ;): 3.81 answers 1 to -q (present), 4.3 answers 0 to -q and to -q -B (idle, fail-closed: such a recipe verifies nothing); verify: +false differs too (3.81: -q 2 and -n 2 = missing; 4.3: -q 1 = present) and on both the root make verify ends non-zero. What runs during the inspection was measured on GNU make 3.81 and 4.3; this repo has no workspace; proven here by monorepo-root-selftest.sh (hermetic by default, MONOREPO_LIVE=1 adds the pnpm cases), one breaking case per rule"
  [_shared/probes/prove-mutation.sh]="agent tool run by prod-implementer in target repos; proven here by prove-mutation-selftest.sh"
  [_shared/probes/gate-run.sh]="agent tool run inside target repos by prod-implementer/mechanic/author; proven by gate-run-selftest.sh"
  [_shared/probes/brand-strings.sh]="scans a generated tree for a user-supplied brand denylist; this repo has neither; run in scaffolded repos, proven here by brand-strings-selftest.sh"
  [prod-new/template/scripts/gate-run.sh]="agent tool, executed in scaffolded repos by agents; edited here, not run here; proven by gate-run-selftest.sh"
  [_shared/probes/acceptance-gap.sh]="orchestrator tool for target repos' held-out acceptance results (this repo has no features); run by prod-review there, proven here by acceptance-gap-selftest.sh"
  [_shared/probes/acceptance-coverage.sh]="gate for target repos' acceptance/<feature>.yaml (this repo has no features); run by prod-spec/prod-review there, proven here by acceptance-coverage-selftest.sh"
)
# A backtick inside a double-quoted reason is COMMAND SUBSTITUTION, not prose:
# on 2026-10-02 one reason said (`make acceptance`, ...) and every load of this
# file ran `make acceptance` in the caller's cwd, blanking the reason and
# printing "No rule to make target" into two implementers' gate logs. The
# source is checked, not the expanded value, because by expansion time the
# command has already run.
#
# CAPTURE, THEN MATCH. `... | grep -q` under pipefail is a race: grep -q exits on
# its first hit, a writer still writing takes SIGPIPE (141), pipefail reports the
# MATCH as a failed pipeline, and `if` reads "no backtick". It fires exactly when
# there IS one. Measured 2026-11-27 at the exception loop below (a false "stale exception"
# FAIL in the pre-commit hook, twice, under load). gate-hygiene-fitness.sh now
# refuses the shape.
exc_src=$(sed -n '/^declare -A EXCEPT=(/,/^)/p' "${BASH_SOURCE[0]}" | grep -v '^[[:space:]]*#')
if grep -q '`' <<<"$exc_src"; then
  echo "probe-wiring: a declared exception's reason contains a backtick -- that is a command, not a reason. Quote with '...'." >&2
  exit 2
fi
probe_lines=$(printf '%s\n' "${PROBES[@]}")
for e in "${!EXCEPT[@]}"; do
  # Out of scope for this run rather than stale: an exception for another tree
  # is not an excuse this scan could be honouring.
  [[ "$(dirname "$e")" == "$PROBE_DIR" ]] || continue
  if ! grep -qxF -- "$e" <<<"$probe_lines"; then
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
