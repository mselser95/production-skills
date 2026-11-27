#!/usr/bin/env bash
# lint-parallel-selftest.sh -- proves scripts/lint-parallel.sh does what its header says.
#
# Hermetic and sequential: every case copies a small temp git repo under one temp root.
# Two kinds of case:
#   fake cases  -- a FAKE `shellcheck` first on PATH logs every file it is asked to lint
#                  and calls a file "dirty" when its content contains the word DIRTY (or
#                  its path matches $FAKE_DIRTY); it can also exit with a chosen code or
#                  kill itself. They pin the orchestration and are fast.
#   real cases  -- named real_*: the REAL shellcheck on small fixtures (cross-file
#                  sourcing, rc files). When shellcheck is not installed they are
#                  SKIPPED and the line says so; a skip is never a silent pass.
# One line per case, then "N ok, M failed". Exit 0 all ok, 1 any failure, 2 none ran.
#
# Usage: lint-parallel-selftest.sh [--mutations]
#   --mutations  apply ONE mutation at a time to a scratch COPY of the subject (the
#                lines carrying a `# MUT:<id>` marker), run the cases that guard it, and
#                require RED. Prints RED/GREEN per mutation; exit 1 on any GREEN.
# Env:   LINT_PARALLEL_SUBJECT  script under test (default ../lint-parallel.sh)
#        LINT_SELFTEST_ONLY     space-separated case names (used by --mutations)
#        LINT_MUT_ONLY          space-separated mutation ids: run only those
#        LINT_SELFTEST_RUNS     set: append the number of subject runs to each case line
set -uo pipefail

case ${BASH_SOURCE[0]} in */*) here=$(cd "${BASH_SOURCE[0]%/*}" && pwd) ;; *) here=$(pwd) ;; esac
subject=${LINT_PARALLEL_SUBJECT:-$here/../lint-parallel.sh}
SELF="$here/${BASH_SOURCE[0]##*/}"
[ -r "$subject" ] || { echo "no subject at $subject" >&2; exit 2; }

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset LINT_JOBS LINT_SEVERITY LINT_FILE_TIMEOUT SHELLCHECK_OPTS FAKE_DIRTY FAKE_RC FAKE_RC_ON FAKE_KILL FAKE_NAP FAKE_HANG FAKE_HANG_ON FAKE_GITGREP_RC XDG_CONFIG_HOME
SD="SCRIPT""DIR" # the keyword, built so these bytes never carry it (a case pins that)

T=$(mktemp -d "${TMPDIR:-/tmp}/lint-parallel-selftest.XXXXXX") || exit 2
cleanup() { case $T in */lint-parallel-selftest.*) rm -rf -- "$T" ;; esac; }
trap cleanup EXIT
BASH_BIN=$BASH
ORIG_PATH=$PATH
mkdir -p "$T/home"; export HOME="$T/home"

# ---- fixtures ---------------------------------------------------------------------
newcase() { # name -> C R FILES_LOG; a repo with a, b, dup(=a), "sp ace/c d"
  C="$T/$1"; R="$C/repo"; FILES_LOG="$C/files"
  mkdir -p "$C/bin"; : > "$FILES_LOG"
  export FILES_LOG
  cat > "$C/bin/shellcheck" <<'FAKE'
#!/bin/sh
printf '%s\n' "$*" >> "$FILES_LOG.argv"
for a in "$@"; do f=$a; done
sev=$3
printf '%s\n' "$f" >> "$FILES_LOG"
[ -z "${FAKE_SLEEP:-}" ] || sleep "0.0$(( $$ % 4 ))"
[ -z "${FAKE_NAP:-}" ] || sleep "$FAKE_NAP"
if [ -n "${FAKE_HANG_ON:-}" ]; then case $f in *"$FAKE_HANG_ON"*) exec sleep "$FAKE_HANG" ;; esac; fi
if [ -n "${FAKE_KILL:-}" ]; then case $f in *"$FAKE_KILL"*) kill -9 $$ ;; esac; fi
if [ -n "${FAKE_RC:-}" ]; then case $f in *"${FAKE_RC_ON:-}"*) echo "fake tool failure"; exit "$FAKE_RC" ;; esac; fi
if [ -n "${FAKE_HOLD_ON:-}" ]; then case $f in *"$FAKE_HOLD_ON"*) echo go > "$FAKE_FIFO"; sleep 1 ;; esac; fi
dirty=0
while IFS= read -r l || [ -n "$l" ]; do case $l in *DIRTY*) dirty=1 ;; esac; done < "$f"
[ -z "${FAKE_DIRTY:-}" ] || case $f in *"$FAKE_DIRTY"*) dirty=1 ;; esac
if [ "$dirty" = 1 ]; then echo "In $f line 1: finding (severity $sev)"; exit 1; fi
exit 0
FAKE
  chmod +x "$C/bin/shellcheck"
  # a git that fails `git grep` on demand (FAKE_GITGREP_RC) and forwards everything else
  printf '#!/bin/sh\n[ "$1" = grep ] && [ -n "${FAKE_GITGREP_RC:-}" ] && { echo "fatal: injected" >&2; exit "$FAKE_GITGREP_RC"; }\nexec "%s" "$@"\n' "$(command -v git)" > "$C/bin/git"
  chmod +x "$C/bin/git"
  if [ ! -d "$T/tmpl" ]; then
    mkdir -p "$T/tmpl/sp ace"
    printf 'echo a\n' > "$T/tmpl/a.sh"; printf 'echo b\n' > "$T/tmpl/b.sh"; printf 'echo a\n' > "$T/tmpl/dup.sh"
    printf 'echo c\n' > "$T/tmpl/sp ace/c d.sh"; printf 'text\n' > "$T/tmpl/readme.txt"
    ( cd "$T/tmpl" && git init -q . && git add -A && git commit -qm init )
  fi
  rm -rf -- "$R"; cp -R "$T/tmpl" "$R"
  unset FAKE_DIRTY FAKE_RC FAKE_RC_ON FAKE_KILL FAKE_SLEEP FAKE_NAP FAKE_HANG FAKE_HANG_ON FAKE_GITGREP_RC LINT_JOBS LINT_SEVERITY LINT_FILE_TIMEOUT SHELLCHECK_OPTS
  export LINT_JOBS=2
}
lc() { # run the subject inside the repo with the fake first on PATH
  printf x >> "$T/runs"
  ( cd "$R" && PATH="$C/bin:$ORIG_PATH" "$BASH_BIN" "$subject" ) > "$C/out" 2> "$C/err"; RC=$?
}
lcr() { # the same with the REAL shellcheck
  printf x >> "$T/runs"
  ( cd "$R" && PATH="$ORIG_PATH" "$BASH_BIN" "$subject" ) > "$C/out" 2> "$C/err"; RC=$?
}
have_real() { command -v shellcheck >/dev/null || { INFO="SKIPPED: real shellcheck is not installed"; return 1; }; }
linted() { wc -l < "$FILES_LOG" | tr -d ' '; }
reset() { : > "$FILES_LOG"; : > "$FILES_LOG.argv"; }
sumline() { grep '^shellcheck:' "$C/out" | head -1; }
commit_all() { ( cd "$R" && git add -A && git commit -qm c ); }
fail() { FAILS="$FAILS $1;"; }
expect() { [ "$2" = "$3" ] || fail "$1: want [$2] got [$3]"; }
sorted_log() { LC_ALL=C sort "$FILES_LOG" | tr '\n' ' '; }
rmfix() { rm "$R/a.sh" "$R/b.sh" "$R/dup.sh" "$R/sp ace/c d.sh"; }
LIBARR='#!/bin/bash\nARR=(1 2)\necho "${ARR[@]}"\n'
SRCSH='#!/bin/bash\n. ./lib.sh\necho "$ARR"\n'
LOOP_DIRTY='#!/bin/bash\nfor f in $(ls); do echo "$f"; done\n' # real finding SC2045

# ---- fake cases -------------------------------------------------------------------
t_cold_lints_each_unique_once_and_remembers_nothing() {
  mkdir "$C/tmp"; TMPDIR="$C/tmp" lc; expect rc 0 "$RC"
  expect lints 3 "$(linted)"
  expect summary "shellcheck: 3 unique script(s) of 4 clean at severity=warning" "$(sumline)"
  expect temp_dir_removed_on_exit 0 "$(find "$C/tmp" -mindepth 1 | wc -l | tr -d ' ')"
  reset; lc; expect second_run_lints_everything_again 3 "$(linted)"
}
t_identical_content_linted_once() {
  rm "$R/b.sh" "$R/sp ace/c d.sh"; commit_all   # a.sh and dup.sh remain, byte-identical
  lc; expect rc 0 "$RC"
  expect lints 1 "$(linted)"; expect which a.sh "$(cat "$FILES_LOG")"
  expect summary "shellcheck: 1 unique script(s) of 2 clean at severity=warning" "$(sumline)"
}
t_findings_printed_and_sharing_paths_listed() {
  printf 'echo DIRTY\n' > "$R/b.sh"
  lc; expect rc1 1 "$RC"
  grep -q 'In b.sh line 1: finding' "$C/out" || fail "findings not printed"
  grep -q 'findings in 1 of 3 unique' "$C/err" || fail "no findings summary on stderr"
  printf 'echo DIRTY\n' > "$R/a.sh"; printf 'echo DIRTY\n' > "$R/dup.sh"; printf 'echo b\n' > "$R/b.sh"; lc
  grep -q 'In a.sh line 1' "$C/out" || fail "finding not under the representative a.sh"
  grep -q 'In dup.sh' "$C/out" && fail "finding printed under the non-representative dup.sh"
  grep -q 'the same verdict holds for dup.sh' "$C/out" || fail "sharing paths not listed: $(cat "$C/out")"
}
t_one_file_per_call_with_x() {
  lc; expect rc 0 "$RC"
  expect calls 3 "$(wc -l < "$FILES_LOG.argv" | tr -d ' ')"
  expect every_call_is_x_S_dashdash 0 "$(grep -vc -- '^-x -S warning -- ' "$FILES_LOG.argv")"
  grep -qx -- '-x -S warning -- sp ace/c d.sh' "$FILES_LOG.argv" || fail "spaced path not passed whole: $(cat "$FILES_LOG.argv")"
  reset; LINT_SEVERITY=style lc; grep -q -- '-x -S style -- ' "$FILES_LOG.argv" || fail "severity not passed"
}
t_untracked_sh_is_not_linted() {
  printf 'echo DIRTY\n' > "$R/scratch.sh"; lc; expect rc 0 "$RC"
  expect lints 3 "$(linted)"
}
t_zero_tracked_sh_is_exit_2() {
  ( cd "$R" && git rm -q a.sh b.sh dup.sh "sp ace/c d.sh" && git commit -qm none )
  lc; expect rc 2 "$RC"
  grep -q 'ZERO shell scripts' "$C/err" || fail "no ZERO message"
}
t_shellcheck_missing_is_exit_2() {
  mkdir -p "$C/empty"
  ( cd "$R" && PATH="$C/empty" "$BASH_BIN" "$subject" ) > "$C/out" 2> "$C/err"; RC=$?
  expect rc 2 "$RC"
  grep -q 'shellcheck missing' "$C/err" || fail "no missing message: $(cat "$C/err")"
}
t_exit_2_is_tool_error_and_beats_findings() {
  FAKE_DIRTY=a.sh FAKE_RC=2 FAKE_RC_ON=b.sh lc; expect rc 2 "$RC"
  grep -q 'TOOL ERROR on b.sh' "$C/err" || fail "no tool-error message: $(cat "$C/err")"
  grep -q 'In a.sh line 1' "$C/out" || fail "the finding was lost behind the tool error"
  grep -q 'findings in' "$C/err" && fail "a tool error was reported as findings"
  FAKE_KILL=b.sh lc; expect killed_rc 2 "$RC"
  grep -q 'TOOL ERROR on b.sh' "$C/err" || fail "a killed shellcheck is not a tool error"
}
t_output_is_identical_for_one_and_four_jobs() {
  local i; mkdir -p "$R/zz" "$R/mm"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do printf 'echo %s %s\n' "$i" "$([ $((i % 3)) = 0 ] && echo DIRTY)" > "$R/f$i.sh"; done
  for i in 1 2 3 4; do printf 'echo DIRTY %s\n' "$i" > "$R/zz/z$i.sh"; printf 'echo DIRTY m%s\n' "$i" > "$R/mm/m$i.sh"; done
  commit_all; export FAKE_SLEEP=1
  LINT_JOBS=1 lc; cp "$C/out" "$C/out1"; expect rc1 1 "$RC"
  LINT_JOBS=4 lc; cmp -s "$C/out1" "$C/out" || fail "stdout differs between LINT_JOBS=1 and 4"
  [ "$(grep -c '^In ' "$C/out")" = 12 ] || fail "expected 12 findings, got $(grep -c '^In ' "$C/out")"
  grep '^In ' "$C/out" | cut -d' ' -f2 > "$C/order"
  LC_ALL=C sort "$C/order" | cmp -s - "$C/order" || fail "findings are not in path order: $(tr '\n' ' ' < "$C/order")"
}
t_odd_filenames() {
  printf 'echo bs\n' > "$R/back\\slash.sh"; printf 'echo dash\n' > "$R/-dash.sh"; commit_all
  lc; expect rc 0 "$RC"
  grep -qxF 'back\slash.sh' "$FILES_LOG" || fail "backslash path not linted whole: $(cat "$FILES_LOG")"
  grep -qxF -- '-dash.sh' "$FILES_LOG" || fail "dash path not linted whole"
  rm "$R/back\\slash.sh"; commit_all
  printf 'echo t\n' > "$R/tab"$'\t'"x.sh"; commit_all; lc; expect rc_tab 2 "$RC"
  rm "$R/tab"$'\t'"x.sh"; commit_all
  if printf 'echo n\n' > "$R/nl"$'\n'"x.sh" 2> /dev/null; then
    commit_all; lc; expect rc_newline 2 "$RC"
    grep -q 'newline or a tab' "$C/err" || fail "no refusal message for the newline path"
  else INFO="newline filename not creatable here; refusal not exercised"; fi
}
t_dedupe_respects_rc_chain() {
  # same content under the same rc chain shares a run; a nearer rc file is a different chain
  local d; mkdir -p "$R/x" "$R/y" "$R/sub"; rmfix
  for d in x y sub; do printf 'echo n\n' > "$R/$d/n.sh"; done
  printf 'disable=SC1000\n' > "$R/.shellcheckrc"; printf 'disable=SC2000\n' > "$R/sub/.shellcheckrc"; commit_all
  lc; expect rc 0 "$RC"
  expect shared_under_one_rc_split_under_another "sub/n.sh x/n.sh " "$(sorted_log)"
}
t_dedupe_respects_scriptdir() {
  # identical plain copies share a run; the keyword in ONE file switches sharing off for
  # the whole run, and a line on stderr names the file
  mkdir -p "$R/d1" "$R/d2" "$R/e1" "$R/e2"; rmfix
  printf 'echo n\n' > "$R/d1/s.sh"; cp "$R/d1/s.sh" "$R/d2/s.sh"; commit_all
  lc; expect shared_when_no_mention "d1/s.sh " "$(sorted_log)"
  grep -q 'dedupe: off' "$C/err" && fail "sharing reported off without a mention"
  printf '#!/bin/bash\n# source-path=%s\n. ./lib.sh\n' "$SD" > "$R/e1/t.sh"; cp "$R/e1/t.sh" "$R/e2/t.sh"; commit_all
  reset; lc; expect off_for_every_path 4 "$(linted)"
  grep -q "dedupe: off -- $SD mentioned in e1/t.sh" "$C/err" || fail "no reason line: $(cat "$C/err")"
}
t_sharing_scan_covers_the_whole_tree() {
  # a mention in an UNTRACKED non-.sh file, then in a TRACKED non-.sh file
  lc; expect clean_baseline 3 "$(linted)"
  printf 'source-path=%s\n' "$SD" > "$R/notes.txt"
  reset; lc; expect untracked_txt 4 "$(linted)"
  grep -q 'dedupe: off -- .* mentioned in notes.txt' "$C/err" || fail "reason missing: $(cat "$C/err")"
  mv "$R/notes.txt" "$R/common.inc"; commit_all
  reset; lc; expect tracked_inc 4 "$(linted)"
}
t_sharing_off_for_opts() {
  local o
  lc; expect baseline 3 "$(linted)"
  reset; SHELLCHECK_OPTS=--exclude=SC2086 lc; expect benign_opts_keep_sharing 3 "$(linted)"
  for o in "--rcfile=$C/x.rc" "-P$C" "-P $C" "--source-path=$C" "--exclude=SC1 $SD"; do
    reset; SHELLCHECK_OPTS=$o lc; expect "opts[$o]" 4 "$(linted)"
    grep -q 'dedupe: off -- .*SHELLCHECK_OPTS' "$C/err" || fail "no reason line for [$o]"
  done
}
t_git_grep_failure_fails_closed() {
  FAKE_GITGREP_RC=128 lc; expect rc 0 "$RC"
  expect shares_nothing 4 "$(linted)"
  grep -q 'dedupe: off -- git grep failed' "$C/err" || fail "reason missing: $(cat "$C/err")"
}
t_sharing_off_for_rc_above_the_root() {
  # $C is the repo's parent: outside git's view, inside shellcheck's rc walk
  printf 'source-path=%s\n' "$SD" > "$C/.shellcheckrc"
  lc; expect shares_nothing 4 "$(linted)"
  grep -q "mentioned in .*/.shellcheckrc" "$C/err" || fail "reason missing: $(cat "$C/err")"
}
t_sharing_off_for_undotted_rc() {
  printf 'source-path=%s\n' "$SD" > "$C/shellcheckrc"
  lc; expect shares_nothing 4 "$(linted)"
}
t_sharing_off_for_user_level_rc() {
  mkdir -p "$C/h2" "$C/h3" "$C/xdg"
  printf 'source-path=%s\n' "$SD" > "$C/h2/.shellcheckrc"
  HOME="$C/h2" lc; expect home_rc 4 "$(linted)"
  printf 'source-path=%s\n' "$SD" > "$C/xdg/shellcheckrc"
  reset; HOME="$C/h3" XDG_CONFIG_HOME="$C/xdg" lc; expect xdg_rc 4 "$(linted)"
}
t_tool_rejecting_its_options_is_exit_2_with_its_message() {
  # the fake prints "fake tool failure" and exits 4, as a shellcheck rejecting an option would
  SHELLCHECK_OPTS=--bogus FAKE_RC=4 lc; expect rc 2 "$RC"
  grep -q "TOOL ERROR on .*fake tool failure" "$C/err" || fail "the tool's first line is not in the message: $(head -2 "$C/err")"
}
t_unreadable_file_is_exit_2() {
  [ "$(id -u)" != 0 ] || { INFO="SKIPPED: running as root, chmod 000 does not hide a file"; return 0; }
  chmod 000 "$R/b.sh"; lc; chmod 644 "$R/b.sh"
  expect rc 2 "$RC"; grep -q 'cannot hash' "$C/err" || fail "no cannot-hash message: $(cat "$C/err")"
}
t_tool_files_do_not_carry_the_keyword() {
  expect lint_script 0 "$(grep -c "$SD" "$here/../lint-parallel.sh")"
  expect selftest 0 "$(grep -c "$SD" "$SELF")"
}
t_term_removes_the_temp_dir() {
  # TERM removes the temp dir (SIGKILL cannot be handled and is not tested). INT is not
  # delivered here: a background job of a non-interactive shell starts with INT ignored.
  mkfifo "$C/fifo"; mkdir "$C/tmp"; local pid
  ( cd "$R" && TMPDIR="$C/tmp" FAKE_FIFO="$C/fifo" FAKE_HOLD_ON=b.sh PATH="$C/bin:$ORIG_PATH" "$BASH_BIN" "$subject" ) > "$C/out" 2> "$C/err" &
  pid=$!
  read -r _ < "$C/fifo"; kill -TERM "$pid"; wait "$pid"; RC=$?
  expect rc_143 143 "$RC"
  expect temp_dir_removed 0 "$(find "$C/tmp" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
}
t_term_kills_the_group_fast() {
  # 20 files at 5 s each: a TERM after 1 s ends the run in < 3 s, kills every worker and
  # fake shellcheck, and removes the temp dir. A guard (bounded, one sleep) kills a script
  # that ignores the TERM, so a broken subject costs 4 s, not 25.
  local i pid guard nap=5.0731 t0; mkdir "$C/tmp"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do printf 'echo %s\n' "$i" > "$R/g$i.sh"; done; commit_all
  ( cd "$R" && TMPDIR="$C/tmp" FAKE_NAP=$nap LINT_JOBS=4 PATH="$C/bin:$ORIG_PATH" "$BASH_BIN" "$subject" ) > "$C/out" 2> "$C/err" &
  pid=$!
  sleep 1
  ( trap 'kill $(jobs -p) 2>/dev/null; exit 0' TERM; sleep 4 & wait $!; kill -KILL "$pid" 2>/dev/null ) &
  guard=$!
  t0=$SECONDS; kill -TERM "$pid"; wait "$pid"; RC=$?
  kill -TERM "$guard" 2>/dev/null; wait "$guard" 2>/dev/null
  expect rc_143 143 "$RC"
  [ $((SECONDS - t0)) -lt 3 ] || fail "took $((SECONDS - t0)) s to exit after TERM"
  pgrep -f "sleep $nap" > /dev/null && fail "a fake shellcheck survived the TERM"
  expect temp_dir_removed 0 "$(find "$C/tmp" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
}
t_file_timeout_is_a_tool_error() {
  local t0=$SECONDS
  LINT_FILE_TIMEOUT=abc lc; expect bad_value_rc 2 "$RC"
  FAKE_HANG_ON=b.sh FAKE_HANG=3171 LINT_FILE_TIMEOUT=1 lc; expect rc 2 "$RC"
  [ $((SECONDS - t0)) -lt 15 ] || fail "took $((SECONDS - t0)) s for a 1 s timeout"
  grep -q 'timeout: b.sh' "$C/err" || fail "message does not name the file: $(cat "$C/err")"
  grep -q 'findings in' "$C/err" && fail "a timeout was reported as findings"
  pgrep -f "sleep 3171" > /dev/null && fail "the hung shellcheck survived"
}
# ---- real shellcheck ---------------------------------------------------------------
t_real_lib_change_flips_verdict() {
  # a.sh uses an array that lib.sh defines: followed with -x, SC2128 fires in a.sh (the old
  # one-call recipe sees it too); a change of only lib.sh flips the verdict on the next run
  have_real || return 0
  rmfix; printf '%b' "$SRCSH" > "$R/a.sh"; printf '%b' "$LIBARR" > "$R/lib.sh"; commit_all
  lcr; expect rc_array 1 "$RC"; grep -q 'SC2128' "$C/out" || fail "SC2128 not reported: $(head -5 "$C/out")"
  ( cd "$R" && shellcheck -S warning a.sh lib.sh > /dev/null 2>&1 ); expect old_recipe_rc 1 "$?"
  printf '#!/bin/bash\nARR=1\necho "$ARR"\n' > "$R/lib.sh"
  lcr; expect rc_scalar 0 "$RC"; expect summary "shellcheck: 2 unique script(s) of 2 clean at severity=warning" "$(sumline)"
  printf '%b' "$LIBARR" > "$R/lib.sh"
  lcr; expect rc_array_again 1 "$RC"
}
t_real_follows_three_forms() {
  # plain `. ./lib.sh`, a `#`-first line that is code (a quote closes on it), a directive
  have_real || return 0
  rmfix
  printf '#!/bin/bash\n. ./lib.sh\necho "$ARR"\n' > "$R/f1.sh"
  printf '#!/bin/bash\necho "a\n#"; . ./lib.sh\necho "$ARR"\n' > "$R/f2.sh"
  printf '#!/bin/bash\n# shellcheck source=lib.sh\n. "$X"\necho "$ARR"\n' > "$R/f3.sh"
  printf '%b' "$LIBARR" > "$R/lib.sh"; commit_all
  lcr; expect rc 1 "$RC"
  expect all_three_reported "f1.sh f2.sh f3.sh" "$(grep '^In ' "$C/out" | cut -d' ' -f2 | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ $//')"
}
t_real_b2_sources_outside_the_tree_flip() {
  # a directive resolving outside the work tree (the CWD is the repo root, so ../lib.sh is
  # the repo's parent) and one naming an untracked root path
  have_real || return 0
  rmfix
  printf '#!/bin/bash\n# shellcheck source=../lib.sh\n. "$X"\necho "$ARR"\n' > "$R/s1.sh"
  printf '#!/bin/bash\n# shellcheck source=untracked.sh\n. "$X"\necho "$ARR"\n' > "$R/s2.sh"; commit_all
  lcr; expect none_there_rc 0 "$RC"
  printf 'ARR=(1 2)\n' > "$C/lib.sh"; printf 'ARR=(1 2)\n' > "$R/untracked.sh"
  lcr; expect created_flips_rc 1 "$RC"
  grep -q '^In s1.sh' "$C/out" || fail "outside-the-tree source not followed: $(head -3 "$C/out")"
  grep -q '^In s2.sh' "$C/out" || fail "untracked root source not followed"
  printf 'ARR=1\n' > "$C/lib.sh"; printf 'ARR=1\n' > "$R/untracked.sh"; lcr; expect changed_flips_back_rc 0 "$RC"
}
t_real_rc_representative_case_b() {
  # identical content at z.sh and sub/a.sh, sub/.shellcheckrc disables the finding: the
  # verdict of each path is its own, whichever is first and whichever is deleted
  have_real || return 0
  rmfix; mkdir -p "$R/sub"
  printf '%b' "$LOOP_DIRTY" > "$R/z.sh"; printf '%b' "$LOOP_DIRTY" > "$R/sub/a.sh"
  printf 'disable=SC2045\n' > "$R/sub/.shellcheckrc"; commit_all
  lcr; expect both_present_rc 1 "$RC"
  grep -q '^In z.sh' "$C/out" || fail "finding not under z.sh"; grep -q '^In sub/a.sh' "$C/out" && fail "sub/a.sh must be clean (its rc disables SC2045)"
  ( cd "$R" && git rm -q z.sh ); lcr; expect only_sub_rc 0 "$RC"
  ( cd "$R" && git reset -q --hard && git rm -q sub/a.sh ); lcr; expect only_z_rc 1 "$RC"
}
t_real_nested_and_ancestor_rc() {
  have_real || return 0
  rmfix; mkdir -p "$R/sub"; printf '%b' "$LOOP_DIRTY" > "$R/sub/a.sh"; commit_all
  lcr; expect no_rc 1 "$RC"
  printf 'disable=SC2045\n' > "$R/sub/.shellcheckrc"; lcr; expect untracked_nested_rc_added 0 "$RC"
  rm "$R/sub/.shellcheckrc"; lcr; expect removed 1 "$RC"
  printf 'disable=SC2045\n' > "$C/.shellcheckrc"; lcr; expect ancestor_above_repo_added 0 "$RC"
}
t_real_dedupe_premise() {
  # the premise of the sharing rule, measured: with -x from the repo root, two identical
  # copies in two directories follow the SAME lib.sh unless the directory-relative source-path keyword is in play, whatever
  # sits next to each copy; with that keyword the directory decides
  have_real || return 0
  rmfix; mkdir -p "$R/d1" "$R/d2"
  printf 'A=1\n' > "$R/d1/lib.sh"; printf 'A=(1 2)\n' > "$R/d2/lib.sh"
  local body='#!/bin/bash\n. ./lib.sh\necho "$A"\n'
  printf '%b' "$body" > "$R/d1/s.sh"; printf '%b' "$body" > "$R/d2/s.sh"
  printf '#!/bin/bash\n# shellcheck source-path=%s\n. ./lib.sh\necho "$A"\n' "$SD" > "$R/d1/t.sh"; cp "$R/d1/t.sh" "$R/d2/t.sh"
  sc() { ( cd "$R" && shellcheck -x -S warning -- "$1" > /dev/null 2>&1; echo $? ); }
  expect plain_copies_agree "$(sc d1/s.sh)" "$(sc d2/s.sh)"
  expect plain_follows_neither_dir_lib 0 "$(sc d2/s.sh)"
  expect scriptdir_d1 0 "$(sc d1/t.sh)"; expect scriptdir_d2_follows_its_own_lib 1 "$(sc d2/t.sh)"
  printf 'A=(1 2)\n' > "$R/lib.sh"
  expect root_array_d1 1 "$(sc d1/s.sh)"; expect root_array_d2 1 "$(sc d2/s.sh)"
  printf 'A=1\n' > "$R/lib.sh"
  expect root_scalar_d1 0 "$(sc d1/s.sh)"; expect root_scalar_d2 0 "$(sc d2/s.sh)"
  INFO="plain copies: dir lib ignored; keyword copies: d1 0, d2 1"
}

t_real_b1_keyword_inside_a_sourced_file() {
  # the keyword sits in a file the script SOURCES (.sh and non-.sh): d2 alone fails SC2128
  have_real || return 0
  local ext
  for ext in sh inc; do
    [ "$ext" != sh ] || rmfix
    rm -rf "$R/d1" "$R/d2" "$R"/common.*; mkdir -p "$R/d1" "$R/d2"
    printf '#!/bin/bash\n# shellcheck source-path=%s\n. lib.sh\n' "$SD" > "$R/common.$ext"
    printf '#!/bin/bash\n. ./common.%s\necho "$ARR"\n' "$ext" > "$R/d1/x.sh"; cp "$R/d1/x.sh" "$R/d2/x.sh"
    printf '#!/bin/bash\nARR=1\necho "$ARR"\n' > "$R/d1/lib.sh"; printf '%b' "$LIBARR" > "$R/d2/lib.sh"; commit_all
    lcr; expect "rc[$ext]" 1 "$RC"
    grep -q '^In d2/x.sh' "$C/out" || fail "[$ext] d2/x.sh finding lost: $(head -3 "$C/out")"
    grep -q 'SC2128' "$C/out" || fail "[$ext] SC2128 not reported"
  done
}
t_real_b2_rcfile_in_opts() {
  # SHELLCHECK_OPTS names an rc (outside the tree) that carries the keyword. --rcfile
  # exists from shellcheck 0.10.0: probe the real tool once and check the probe against
  # the version, so a skip is never silent and never happens when the option exists.
  # The property itself (--rcfile in the opts switches sharing off) is carried,
  # unconditionally, by the FAKE case sharing_off_for_opts.
  have_real || return 0
  local ver maj min want got
  ver=$(shellcheck --version | sed -n 's/^version: //p'); maj=${ver%%.*}; min=${ver#*.}; min=${min%%.*}
  want=no; { [ "${maj:-0}" -gt 0 ] || [ "${min:-0}" -ge 10 ]; } 2> /dev/null && want=yes
  printf '#!/bin/bash\n:\n' > "$C/probe.sh"
  got=no; shellcheck --rcfile /dev/null "$C/probe.sh" > /dev/null 2>&1 && got=yes
  expect rcfile_probe_matches_version_$ver "$want" "$got"
  [ -z "$FAILS" ] || return 0
  if [ "$got" = no ]; then SKIP="shellcheck $ver has no --rcfile"; return 0; fi
  rmfix; mkdir -p "$R/d1" "$R/d2"
  printf '#!/bin/bash\n. ./lib.sh\necho "$ARR"\n' > "$R/d1/x.sh"; cp "$R/d1/x.sh" "$R/d2/x.sh"
  printf '#!/bin/bash\nARR=1\necho "$ARR"\n' > "$R/d1/lib.sh"; printf '%b' "$LIBARR" > "$R/d2/lib.sh"; commit_all
  printf 'source-path=%s\n' "$SD" > "$C/custom.rc"
  SHELLCHECK_OPTS="--rcfile=$C/custom.rc" lcr; expect rc 1 "$RC"
  grep -q '^In d2/x.sh' "$C/out" || fail "d2/x.sh finding lost: $(head -3 "$C/out")"
}

CASES="cold_lints_each_unique_once_and_remembers_nothing identical_content_linted_once findings_printed_and_sharing_paths_listed one_file_per_call_with_x untracked_sh_is_not_linted zero_tracked_sh_is_exit_2 shellcheck_missing_is_exit_2 exit_2_is_tool_error_and_beats_findings output_is_identical_for_one_and_four_jobs odd_filenames dedupe_respects_rc_chain dedupe_respects_scriptdir sharing_scan_covers_the_whole_tree sharing_off_for_opts git_grep_failure_fails_closed sharing_off_for_rc_above_the_root sharing_off_for_undotted_rc sharing_off_for_user_level_rc tool_rejecting_its_options_is_exit_2_with_its_message unreadable_file_is_exit_2 tool_files_do_not_carry_the_keyword term_removes_the_temp_dir term_kills_the_group_fast file_timeout_is_a_tool_error real_lib_change_flips_verdict real_follows_three_forms real_b2_sources_outside_the_tree_flip real_rc_representative_case_b real_nested_and_ancestor_rc real_dedupe_premise real_b1_keyword_inside_a_sourced_file real_b2_rcfile_in_opts"

one_case() {
  local n=$1 want=""
  newcase "$n"; FAILS=""; INFO=""; SKIP=""
  "t_$n"
  [ -z "$INFO" ] || want=" ($INFO)"
  if [ -n "$SKIP" ] && [ -z "$FAILS" ]; then printf 'SKIPPED %s: %s\n' "$n" "$SKIP"
  elif [ -z "$FAILS" ]; then printf 'ok   %s%s\n' "$n" "$want"; else printf 'FAIL %s:%s\n' "$n" "$FAILS"; fi
}
run_cases() {
  local n ok=0 bad=0 skipped=0 line total=0 r0 r1
  : > "$T/runs"
  for n in $CASES; do
    if [ -n "${LINT_SELFTEST_ONLY:-}" ]; then case " $LINT_SELFTEST_ONLY " in *" $n "*) ;; *) continue ;; esac; fi
    total=$((total + 1))
    r0=$(wc -c < "$T/runs"); line=$(one_case "$n" 2>&1); r1=$(wc -c < "$T/runs")
    [ -z "${LINT_SELFTEST_RUNS:-}" ] || line="$line [runs $((r1 - r0))]"
    printf '%s\n' "$line"
    case $line in ok*) ok=$((ok + 1)) ;; SKIPPED*) skipped=$((skipped + 1)) ;; *) bad=$((bad + 1)) ;; esac
  done
  printf '%s ok, %s failed, %s skipped (%s runs of the subject)\n' "$ok" "$bad" "$skipped" "$(wc -c < "$T/runs" | tr -d ' ')"
  [ "$total" -gt 0 ] || { echo "no case ran" >&2; exit 2; }
  [ "$bad" -eq 0 ]
}

# ---- mutations --------------------------------------------------------------------
# id @@ marker=replacement line (';;' separates several) @@ guarding cases
MUTATIONS=$(cat <<'XEOF'
x-removed@@noxflag=X=@@one_file_per_call_with_x real_lib_change_flips_verdict
dashdash-removed@@dashdash=DD=@@one_file_per_call_with_x
dedupe-removed@@dedupe=      k = H[i] "|" P[i]@@identical_content_linted_once cold_lints_each_unique_once_and_remembers_nothing
dedupe-ignores-rc-chain@@rcdedupe=      k = k@@dedupe_respects_rc_chain real_rc_representative_case_b
dedupe-ignores-the-off-switch@@sdirdedupe=      if (0) k = k "|" p@@dedupe_respects_scriptdir
zero-files-guard-removed@@zeroguard=  :@@zero_tracked_sh_is_exit_2
exit-ge2-mapped-to-findings@@rc1=    [1-9]*)@@exit_2_is_tool_error_and_beats_findings
exit-ge2-mapped-to-clean@@rc0=    0 | [2-9]* | 1[0-9][0-9])@@exit_2_is_tool_error_and_beats_findings
output-sort-removed@@sortpipe=  }' "$T/dirrc" "$T/rchash" "$T/paths" "$T/hashes" > "$T/groups"@@output_is_identical_for_one_and_four_jobs
untracked-files-linted@@gitls=find . -name '*.sh' -not -path './.git/*' -print0 > "$T/files0"@@untracked_sh_is_not_linted
shellcheck-missing-guard-removed@@missing=:@@shellcheck_missing_is_exit_2
global-scan-removed@@scan=g=1;;rcscan=if false; then@@sharing_scan_covers_the_whole_tree
scan-limited-to-tracked-sh@@scan=LC_ALL=C xargs -0 grep -a -l -e "$sd" -- < "$T/files0" > "$T/gg" 2>/dev/null; if [ -s "$T/gg" ]; then g=0; else g=1; fi@@sharing_scan_covers_the_whole_tree real_b1_keyword_inside_a_sourced_file
rcfile-not-disabling@@optsrcfile=:@@sharing_off_for_opts real_b2_rcfile_in_opts
dash-P-not-disabling@@optsp=:@@sharing_off_for_opts
source-path-not-disabling@@optssp=:@@sharing_off_for_opts
git-grep-failure-as-no-match@@gitgrepfail=:@@git_grep_failure_fails_closed
term-not-killing-the-group@@termkill=:@@term_kills_the_group_fast
timeout-mapped-to-clean@@tomark=rc=0@@file_timeout_is_a_tool_error
timeout-mapped-to-findings@@tomark=rc=1@@file_timeout_is_a_tool_error
rc-above-root-ignored@@abovewalk=break@@sharing_off_for_rc_above_the_root
undotted-rc-ignored@@undotted=for rn in .shellcheckrc; do [ ! -f "$a/$rn" ] || printf '%s\0' "$a/$rn"; done@@sharing_off_for_undotted_rc
user-rc-ignored@@userrc=globals=(/nonexistent/rc)@@sharing_off_for_user_level_rc
XEOF
)
mutate_line() { # file id replacement
  local f=$1 id=$2 repl=$3
  REPL=$repl ID=$id awk '{ if (index($0, "# MUT:" ENVIRON["ID"]) && $0 ~ ("# MUT:" ENVIRON["ID"] "$")) print ENVIRON["REPL"]; else print }' "$f" > "$f.m" && mv "$f.m" "$f"
}
mutant_parses() { # does the mutant RUN through to its end on a clean fixture without a shell syntax error?
  newcase mutctl
  ( cd "$R" && PATH="$C/bin:$ORIG_PATH" "$BASH_BIN" "$1" ) > "$C/out" 2> "$C/err"
  ! grep -Eq 'syntax error|unexpected (token|EOF)' "$C/err"
}
run_mutations() {
  local line id spec cases rest pair mid repl d out red=0 green=0 base
  mkdir -p "$T/mut"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    id=${line%%@@*}; line=${line#*@@}; spec=${line%%@@*}; cases=${line#*@@}
    if [ -n "${LINT_MUT_ONLY:-}" ]; then case " $LINT_MUT_ONLY " in *" $id "*) ;; *) continue ;; esac; fi
    d="$T/mut/$id"; mkdir -p "$d"; cp "$subject" "$d/lint-parallel.sh"
    rest=$spec
    while [ -n "$rest" ]; do
      case $rest in *';;'*) pair=${rest%%;;*}; rest=${rest#*;;} ;; *) pair=$rest; rest="" ;; esac
      mid=${pair%%=*}; repl=${pair#*=}
      mutate_line "$d/lint-parallel.sh" "$mid" "$repl"
    done
    if cmp -s "$subject" "$d/lint-parallel.sh"; then printf 'ERROR %-30s mutation did not change the script (marker missing?)\n' "$id"; green=$((green + 1)); continue; fi
    if ! mutant_parses "$d/lint-parallel.sh"; then printf 'ERROR %-30s mutant does not parse: %s\n' "$id" "$(grep -E 'syntax error|unexpected' "$C/err" | head -1)"; green=$((green + 1)); continue; fi
    out=$(LINT_PARALLEL_SUBJECT="$d/lint-parallel.sh" LINT_SELFTEST_ONLY="$cases" "$BASH_BIN" "$SELF" 2>&1); base=$?
    if [ "$base" -eq 1 ]; then printf 'RED   %-30s %s\n' "$id" "$(printf '%s\n' "$out" | grep '^FAIL' | head -1 | cut -c1-100)"; red=$((red + 1))
    else printf 'GREEN %-30s the guarding case(s) [%s] still pass: that part is unguarded\n' "$id" "$cases"; green=$((green + 1)); fi
  done <<MUTEOF
$MUTATIONS
MUTEOF
  printf '%s RED, %s not RED\n' "$red" "$green"
  [ "$green" -eq 0 ]
}

if [ "${1:-}" = "--mutations" ]; then
  run_mutations
  exit $?
fi
run_cases
