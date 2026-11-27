#!/usr/bin/env bash
# gate-hygiene-fitness.sh — refuse the shapes a SHELL GATE uses to report
# success while doing nothing.
#
# WHY THIS EXISTS, and why it is separate from error-handling-fitness.sh. That
# gate reads Go, and its subject is the handler that swallows an error. This
# one reads the repo's own scripts/, and its subject is the GATE ITSELF -- the
# thing that decides whether every other check ran. A gate's failures are
# asymmetric: an extractor that stops matching yields an empty measurement, not
# a red row, so the direction it fails in is the direction that flatters.
#
# Every pattern below was MEASURED on 2026-08-27 inside a harness this
# framework wrote to prove a durability property. All four were found by
# mutation, none by reading, and every one produced a confident green. They are
# recorded in _shared/preamble.md §4b; this file is the mechanical half.
#
# WHAT IT CHECKS:
#
#   PKILL-X-FALSE-SUCCESS   `pkill -x <name>` (busybox) matches the command
#                           LINE, not the name, and exits 0 having signalled
#                           nothing. A kill that succeeded is not a process
#                           that died: kill by PID, then prove /proc is gone.
#   PREFIX-ASSIGN-EXPAND    `VAR=x cmd --file $VAR/f` -- the assignment applies
#                           to the command, but $VAR expanded BEFORE it took
#                           effect, so the command reads a path nobody is
#                           testing. Use `export VAR=...; cmd`.
#   BARE-GREP-UNDER-SET-E   a bare `grep` whose no-match exit 1 is the PASSING
#                           case, in a script running `set -e`: the gate then
#                           fails exactly on the runs where nothing was wrong.
#   GREPQ-UNDER-PIPEFAIL    `cmd | grep -q p` with `set -o pipefail`: grep -q
#                           exits on first match, the writer takes SIGPIPE and
#                           dies 141, pipefail propagates 141, and the caller
#                           reads "not found" -- so the check inverts EXACTLY
#                           when it succeeds. Capture first, match the variable.
#                           FAILING since 2026-11-27 (it was advisory): see the
#                           note above `grepq_pipe` for the incident. `a || grep
#                           -q p` is not a pipe and is not flagged.
#   BASH-N-AS-VALIDATION    `bash -n` presented as having validated a script.
#                           It parses and executes nothing; a script that dies
#                           on its first line passes it.
#
# HONEST SCOPE, because a check that overclaims is worse than one that scopes
# itself. This is a TEXT pass over shell sources, not a parse. Known false
# negatives, none of which anything here claims to cover:
#
#   * an indirect kill (a variable holding `pkill -x`, a helper function).
#   * a prefix assignment whose variable is expanded on a later line -- only
#     the same-line shape is detectable this way, and it is the common one.
#   * `grep` inside a command substitution or an `if`, where exit 1 is handled
#     by the construct; those are EXCLUDED deliberately rather than reported,
#     since flagging them would fire on correct code and a gate that fires on
#     correct code gets widened until it is gone.
#   * anything inside a heredoc or a single-quoted block, which this pass does
#     not tokenize.
#   * under bash 3.2 `read` truncates a line at a NUL byte, so a line containing
#     one is judged on its stripped-then-truncated form; bash 4+ and Linux are unaffected.
#
# It has no known false positives over this template, which is the other half
# of the bargain.
#
#   gate-hygiene-fitness.sh              scan scripts/ and benchmarks/
#   gate-hygiene-fitness.sh path [...]   scan only those paths
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" || exit 2

paths=("$@")
[[ ${#paths[@]} -eq 0 ]] && paths=(scripts benchmarks)

files=()
while IFS= read -r f; do files+=("$f"); done < <(
  find "${paths[@]}" -type f -name '*.sh' 2>/dev/null | sort
)

# ZERO INPUTS IS A FAILURE, NOT A CLEAN RUN. A scan whose file list came back
# empty did the least work possible and would otherwise be indistinguishable
# from a scan that found nothing wrong -- this framework's oldest defect shape.
if [[ ${#files[@]} -eq 0 ]]; then
  printf 'gate-hygiene-fitness: no shell sources found under %s -- a scan of nothing is not a clean scan.\n' "${paths[*]}" >&2
  exit 2
fi

# Contexts in which grep's exit 1 is already handled by the construct around
# it. Single-quoted so the backtick stays a literal.
guarded='(\|\||&&|if |while |until |\$\(|`)'
# The prefix-assignment shape. Single-quoted for the same reason `guarded` is:
# an unquoted `;` or `|` inside [[ =~ ]] is parsed by bash as syntax, not as
# pattern, and it reports the error on a line number that is not the mistake.
# This file has now hit that twice while being written, which is a fair
# argument for the rule it enforces two lines down.
prefix_assign='^[[:space:]]*([A-Za-z_][A-Za-z_0-9]*)=[^[:space:];&|]+[[:space:]]+([^;&|]*)$'
pkill_x='pkill[[:space:]]+(-[a-zA-Z0-9]+[[:space:]]+)*-[a-zA-Z]*x'
grepq_pipe='(^|[^|])\|[[:space:]]*grep[[:space:]]+(-[a-zA-Z]*[[:space:]]+)*-[a-zA-Z]*q'
findings=0
# GREPQ-UNDER-PIPEFAIL WAS ADVISORY until 2026-11-27, and the reason it gave was
# "latent, not broken": whether the writer takes SIGPIPE depends on whether it is
# still writing when grep exits, so a small `printf` rarely trips it. That was
# measured, and it was true, and it is exactly why it was dangerous: a race is
# not a defect that stays latent, it is one that waits for load. On 2026-11-27 the
# pre-commit hook's `make check-fast` FAILED TWICE in probe-wiring.sh with
# "declared exception 'prod-new/template/scripts/kill-durability.sh' names a probe
# that does not exist" -- the file existed; `printf '%s\n' "${PROBES[@]}" | grep
# -qxF -- "$e"` lost the race on a loaded machine, took 141, and pipefail turned
# the match into a miss. It passed 3/3 when idle, which is what "latent" looks
# like from the outside. Reproduced with a list larger than the pipe buffer: 50 of
# 50 iterations false-FAIL (probe-wiring-selftest.sh case 13).
#
# So it FAILS now. The call sites that had accumulated were fixed in the same
# change (capture the output, match the variable), leaving zero, so promoting it
# costs nothing today and a new one is refused when written. The regex also no
# longer reads `||` as a pipe: `grep -q a <<<"$x" || grep -q b <<<"$x"` has no
# writer to kill, and two advisories of the four were exactly that.
# The one-pass sed output lives in a temp file; remove it on every way out
# (normal end, early exit, INT/TERM -- bash runs the EXIT trap for those).
strip_tmp=""
trap '[[ -n "$strip_tmp" ]] && rm -f "$strip_tmp"' EXIT
# In one-pass mode a file's findings are held until the file is known to be in
# lockstep with its stripped copy (see scan_file), so a rescan cannot report twice.
report() {
  if (( per_line )); then
    printf '  %s:%s  %-22s %s\n' "$1" "$2" "$3" "$4"; findings=$((findings+1))
  else
    printf -v one '  %s:%s  %-22s %s\n' "$1" "$2" "$3" "$4"; file_out+="$one"; file_findings=$((file_findings+1))
  fi
}
no_tmp=0; per_line=0; file_out=""; file_findings=0; one=""

# One file, scanned in lockstep with its quote-stripped copy on fd 3 (or, when
# per_line is set, stripping each line itself). Returns 1 if the two went out of
# step -- fd 3 short of the source, or lines left over at the end -- so the caller
# can rescan that file per line instead of judging lines against the wrong text.
scan_file() {
  local n=0 line unquoted var rest
  file_out=""; file_findings=0
  {
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n+1))
    if (( ! per_line )); then
      # fd 3 ran dry before the source did: out of lockstep, rescan per line.
      IFS= read -r unquoted <&3 || [[ -n "$unquoted" ]] || return 1
    fi
    [[ "$line" =~ ^[[:space:]]*# ]] && continue

    # `-[a-zA-Z0-9]+`, not `-[a-zA-Z]+`: the first version of this rule could
    # not match `pkill -9 -x name`, which is the exact line that motivated the
    # rule — a signal flag is a DIGIT. It was written, shipped green, and
    # found by mutation testing minutes later. A rule that cannot fire is the
    # vacuous gate this whole file exists to refuse.
    if [[ "$line" =~ $pkill_x ]]; then
      report "$f" "$n" "PKILL-X-FALSE-SUCCESS" "exits 0 having signalled nothing; kill by PID and prove /proc is gone"
    fi

    # A PREFIX assignment applies to one command and nothing else:
    #     VAR=x cmd --file $VAR/f
    # A SEQUENTIAL assignment is a statement of its own and is entirely
    # correct:
    #     VAR=x; cmd --file $VAR/f          id="${BASH_REMATCH[1]}"; id="$(f "$id")"
    # The discriminator is the separator, and getting it wrong matters more
    # than catching the case: measured on this template, the separator-blind
    # form of this rule produced NINE findings and all nine were correct code
    # (check-registries.sh's field capture, kill-durability.sh's counters).
    # A gate that fires on correct code is widened until it is gone, so the
    # rule only fires when NOTHING separates the assignment from the command
    # that expands the variable.
    if [[ "$line" =~ $prefix_assign ]]; then
      var="${BASH_REMATCH[1]}"; rest="${BASH_REMATCH[2]}"
      # `rest` is the command and its arguments, already known to carry no
      # `;`, `&&` or `||` — so if it expands the variable, the expansion
      # happened before the assignment took effect.
      if [[ "$rest" == *"\$$var"* || "$rest" == *"\${$var}"* ]]; then
        report "$f" "$n" "PREFIX-ASSIGN-EXPAND" "\$$var expands BEFORE the assignment applies; use: export $var=...; cmd"
      fi
    fi

    # The guarded-context alternatives live in a single-quoted variable, not
    # inline: an unquoted backtick inside [[ =~ ]] opens a command
    # substitution, and bash reports it as an EOF error 16 lines later. Found
    # by running this file, which is the discipline it exists to enforce.
    if (( uses_set_e )) && [[ "$line" =~ ^[[:space:]]*grep[[:space:]] ]] \
       && [[ ! "$line" =~ $guarded ]]; then
      report "$f" "$n" "BARE-GREP-UNDER-SET-E" "no-match exit 1 is the PASSING case; terminate it explicitly (|| true) and check the count"
    fi

    # QUOTED SPANS REMOVED FIRST, for the same reason the rule below says
    # COMMAND POSITION ONLY. Measured 2026-08-29: this rule reported 11
    # advisories, and TEN of them were the test corpus of probe-self-gate-
    # selftest.sh -- lines like
    #   check FIRE "plain pipe into grep -q" 'go doc ./p | grep -q Foo'
    # where the hazard is the test DATA, not something the file executes. The one
    # true positive was buried among them, which is the actual cost: an advisory
    # lane that is 91% noise is one nobody reads, so the real finding sat there
    # for weeks. (It was error-handling-fitness-selftest.sh, whose assertion
    # inverted exactly when it succeeded; demonstrated with 40MB of output and
    # the needle on line 1, and fixed.)
    #
    # Stripping quoted spans keeps real pipelines: `printf '%s\n' "$out" | grep
    # -qF "$needle"` still matches once its quoted arguments are gone, because
    # the pipe and the grep are not inside quotes. A fixture line collapses to
    # its bare command words and stops matching.
    # ONE sed pass, not a bash substitution loop. The first version stripped the
    # spans with `${unquoted/${BASH_REMATCH[1]}/}` inside a while, which HANGS:
    # that expansion treats its pattern as a GLOB, so a match containing `*` or
    # `[` -- and these lines are full of both -- never matches itself, the string
    # never shrinks, and the loop spins forever. Killed at 2 minutes on the first
    # run. A stripping step that cannot terminate is worse than the false
    # positives it was written to remove.
    # (`unquoted` came from the one-pass sed on fd 3, unless sed refused the file.)
    if (( per_line )); then
      unquoted=$(printf '%s' "$line" | sed "s/'[^']*'//g; s/\"[^\"]*\"//g")
    fi
    if (( uses_pipefail )) && [[ "$unquoted" =~ $grepq_pipe ]]; then
      report "$f" "$n" "GREPQ-UNDER-PIPEFAIL" "grep -q kills the writer with SIGPIPE (141); pipefail turns the MATCH into a false. Capture the output and match the variable"
    fi

    # COMMAND POSITION ONLY. The bare match caught the words wherever they
    # appeared, including inside a quoted MESSAGE -- measured 2026-08-29, this
    # rule flagged verify-standard.sh:1239, an evidence string whose text
    # explains that a script is checked "for parseability (bash -n)" and
    # explicitly NOT executed. A line honouring this rule, reported as breaking
    # it.
    #
    # A rule that punishes documenting its own lesson is one people route
    # around: the fix everyone reaches for is to delete the explanation, and
    # then nobody knows why the script is not run. The match now requires
    # `bash -n` to START a command -- line start, or after `if`, `!`, `then`,
    # `&&`, `||`, `;`, `(`, `$(` -- which covers every shape that RUNS it and
    # none that merely name it.
    #
    # Still caught: `bash -n f`, `if ! bash -n f; then`, `bash -n f || exit 1`,
    # `x=$(bash -n f)`. Not caught: the words inside a string. Comments were
    # already stripped upstream; strings were not, and that was the gap.
    if [[ "$line" =~ (^|[\;\&\|\(]|if|then|\!)[[:space:]]*bash[[:space:]]+-n[[:space:]] ]]; then
      report "$f" "$n" "BASH-N-AS-VALIDATION" "parses and executes nothing; run the gate, then break what it guards and watch it go red"
    fi
  done
  if (( ! per_line )) && IFS= read -r unquoted <&3; then return 1; fi
  } < "$f" 3< "$fd3src"
  return 0
}

for f in "${files[@]}"; do
  # This file documents the patterns it hunts, so scanning it finds its own
  # prose. Named explicitly rather than skipped by a wildcard, so a future
  # exclusion has to be argued for.
  [[ "$f" == */gate-hygiene-fitness.sh ]] && continue
  [[ "$f" == */gate-hygiene-fitness-selftest.sh ]] && continue

  uses_set_e=0
  grep -qE '^[[:space:]]*set[[:space:]]+-[a-z]*e' "$f" && uses_set_e=1
  # pipefail, however it was spelled. The first version of this line required
  # `-o` as a separate token and therefore missed `set -euo pipefail`, which is
  # how almost every script in this repo spells it -- a rule that could not
  # fire, found by mutation and not by reading, for the third time in this
  # file. The lesson is in the pattern, not in the regex: a detector whose
  # trigger condition is itself a match must be mutated too, not only the
  # thing it detects.
  uses_pipefail=0
  grep -qE '^[[:space:]]*set[[:space:]].*pipefail' "$f" && uses_pipefail=1

  # The quote-stripped text of the WHOLE file, one sed process per file (not one
  # per line), read in lockstep with the source on fd 3. sed is line-for-line, so
  # line N there is line N here; it is read BEFORE the comment `continue` in
  # scan_file so a skipped line cannot shift the pairing. If sed refuses the file
  # (an illegal byte sequence aborts it mid-stream), or the two fall out of step,
  # the file is stripped line by line instead, which is what this gate did before
  # and reports the same. If no temp file can be made at all, EVERY file is: the
  # gate must still scan on a read-only filesystem, and must never call a scan it
  # could not do clean.
  per_line=$no_tmp
  fd3src=/dev/null
  if (( ! no_tmp )); then
    if strip_tmp=$(mktemp "${TMPDIR:-/tmp}/hygiene-fitness.XXXXXX" 2>/dev/null); then
      if sed "s/'[^']*'//g; s/\"[^\"]*\"//g" "$f" > "$strip_tmp" 2>/dev/null; then
        fd3src=$strip_tmp
      else
        per_line=1
      fi
    else
      strip_tmp=""; no_tmp=1; per_line=1
      printf 'gate-hygiene-fitness: note: cannot create a temp file under %s; scanning line by line (slower, same result).\n' "${TMPDIR:-/tmp}" >&2
    fi
  fi
  if ! scan_file; then per_line=1; fd3src=/dev/null; scan_file; fi
  printf '%s' "$file_out"; findings=$((findings+file_findings))
  if [[ -n "$strip_tmp" ]]; then rm -f "$strip_tmp"; strip_tmp=""; fi
done

if (( findings )); then
  printf 'gate-hygiene-fitness: %d finding(s) across %d shell file(s).\n' "$findings" "${#files[@]}" >&2
  printf 'Each is a shape measured reporting SUCCESS while doing nothing (see _shared/preamble.md §4b).\n' >&2
  exit 1
fi
printf 'gate-hygiene-fitness: clean -- %d shell file(s), 0 findings.\n' "${#files[@]}"
