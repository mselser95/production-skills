#!/usr/bin/env bash
# lint-parallel-selftest.sh -- proves scripts/lint-parallel.sh does what its header says.
#
# Hermetic: every case copies a small temp git repo under one temp root. Two kinds of case:
#   fake cases  -- a FAKE `shellcheck` first on PATH logs every file it is asked to lint
#                  and calls a file "dirty" when its content contains the word DIRTY (or
#                  its path matches $FAKE_DIRTY); it can also exit with a chosen code,
#                  kill itself, nap, hang or ignore TERM. They pin the mechanics.
#   real cases  -- named t_real_*: the REAL shellcheck on small fixtures (cross-file
#                  sourcing, the directory-relative source-path fixtures, rc options).
#                  Without shellcheck they are SKIPPED, the line says why and the final
#                  line counts skips apart from ok.
# Every subject run is guarded: a hang is a FAIL line, never a stuck selftest.
# One line per case, then "N ok, M failed, K skipped (R runs of the subject)".
# Exit 0 all ok, 1 any failure, 2 none ran.
#
# Usage: lint-parallel-selftest.sh [--mutations]
#   --mutations  apply ONE mutation at a time to a scratch COPY of the subject (the lines
#                carrying a `# MUT:<id>` marker) or of this selftest, run the cases that
#                guard it, and require RED. Prints RED/GREEN per mutation; exit 1 on any GREEN.
# Env:   LINT_PARALLEL_SUBJECT   script under test (default ../lint-parallel.sh)
#        LINT_SELFTEST_ONLY      space-separated case names (used by --mutations)
#        LINT_MUT_ONLY           space-separated mutation ids: run only those
#        LINT_SELFTEST_RUNS      set: append the number of subject runs to each case line
#        LINT_SELFTEST_FORCE_RCF set: the abbreviated-option probe reports "supported"
#                                (it can only make a case RUN; nothing in the environment skips one)
set -uo pipefail

case ${BASH_SOURCE[0]} in */*) here=$(cd "${BASH_SOURCE[0]%/*}" && pwd) ;; *) here=$(pwd) ;; esac
subject=${LINT_PARALLEL_SUBJECT:-$here/../lint-parallel.sh}
SELF="$here/${BASH_SOURCE[0]##*/}"
[ -r "$subject" ] || { echo "no subject at $subject" >&2; exit 2; }

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset LINT_JOBS LINT_SEVERITY LINT_FILE_TIMEOUT SHELLCHECK_OPTS FAKE_DIRTY FAKE_RC FAKE_RC_ON FAKE_KILL FAKE_NAP FAKE_HANG FAKE_HANG_ON FAKE_IGNORE_TERM FAKE_SPAWN XDG_CONFIG_HOME
SD="SCRIPT""DIR" # the directory-relative source-path keyword, for the real fixtures

T=$(mktemp -d "${TMPDIR:-/tmp}/lp.XXXXXX") || exit 2
BASH_BIN=$BASH
ORIG_PATH=$PATH
ORIG_TMPDIR=${TMPDIR:-}
REALSLEEP=$(command -v sleep)
# PROCESS HYGIENE. No pattern here matches a process that is not this run's: every helper carries $T in its
# command line (sleeps go through the wrapper $C/bin/sleep, which records its pid and runs as `$C/sl <n>`; the
# subject gets TMPDIR under $C, so its workers carry $C too; fakes are scripts under $C) or has its pid in
# $C/files.pids. $C/foreign.pids holds deliberate decoys, killed unconditionally.
leak_check() { # print the pids of this run that are alive: carrying $T, or recorded in a pid file; one settle, one re-check
  local p out="" f n=0
  while [ "$n" -lt 2 ]; do
    out=""
    for p in $(pgrep -f "$T"); do out="$out $p"; done
    for f in "$T"/*/files.pids "$T"/*/foreign.pids; do # MUT:leakpids
      [ -f "$f" ] || continue
      for p in $(cat "$f"); do kill -0 "$p" 2> /dev/null && out="$out $p"; done
    done
    [ -n "$out" ] || break
    n=$((n + 1)); [ "$n" -ge 2 ] || sleep 0.3
  done
  printf '%s' "$out"
}
reap_all() { # KILL (never TERM: a helper may ignore it) everything of this run, then say what is still alive
  local p f
  for p in $(pgrep -f "$T"); do kill -KILL "$p" 2> /dev/null; done # MUT:reapkill
  for f in "$T"/*/files.pids; do
    [ -f "$f" ] || continue
    for p in $(cat "$f"); do
      case $(ps -o command= -p "$p" 2> /dev/null) in *"$T"*) kill -KILL "$p" 2> /dev/null ;; esac
    done
  done
  for f in "$T"/*/foreign.pids; do
    [ -f "$f" ] || continue
    for p in $(cat "$f"); do kill -KILL "$p" 2> /dev/null; done
  done
  [ -z "$(pgrep -f "$T")" ]
}
cleanup() { reap_all; case $T in */lp.*) rm -rf -- "$T" ;; esac; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
mkdir -p "$T/home"; export HOME="$T/home"
HARD=40 # seconds: the guard that turns a hung subject into a FAIL line

# ---- fixtures ---------------------------------------------------------------------
newcase() { # name -> C R FILES_LOG; a repo with a, b, dup(=a), "sp ace/c d"
  C="$T/k$(printf %s "$1" | cksum | cut -d" " -f1)"; R="$C/repo"; FILES_LOG="$C/files"
  mkdir -p "$C/bin"; : > "$FILES_LOG"
  export FILES_LOG
  cat > "$C/bin/shellcheck" <<'FAKE'
#!/bin/sh
echo $$ >> "$FILES_LOG.pids"
printf '%s\n' "$*" >> "$FILES_LOG.argv"
for a in "$@"; do f=$a; done
sev=$3
printf '%s\n' "$f" >> "$FILES_LOG"
[ -z "${FAKE_IGNORE_TERM:-}" ] || trap '' TERM
if [ -n "${FAKE_SPAWN:-}" ]; then case $f in *b.sh*) trap '' TERM; sleep "$FAKE_SPAWN" & sleep "$FAKE_SPAWN" ;; esac; fi
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
  printf '#!/bin/bash\necho $$ >> "$FILES_LOG.pids"\nexec -a "${FILES_LOG%%/files}/sl" "%s" "$@"\n' "$REALSLEEP" > "$C/bin/sleep"
  chmod +x "$C/bin/sleep"; mkdir -p "$C/tmp"
  if [ ! -d "$T/tmpl" ]; then
    mkdir -p "$T/tmpl/sp ace"
    printf 'echo a\n' > "$T/tmpl/a.sh"; printf 'echo b\n' > "$T/tmpl/b.sh"; printf 'echo a\n' > "$T/tmpl/dup.sh"
    printf 'echo c\n' > "$T/tmpl/sp ace/c d.sh"; printf 'text\n' > "$T/tmpl/readme.txt"
    ( cd "$T/tmpl" && git init -q . && git add -A && git commit -qm init )
  fi
  rm -rf -- "$R"; cp -R "$T/tmpl" "$R"
  unset FAKE_DIRTY FAKE_RC FAKE_RC_ON FAKE_KILL FAKE_NAP FAKE_HANG FAKE_HANG_ON FAKE_IGNORE_TERM FAKE_SPAWN LINT_JOBS LINT_SEVERITY LINT_FILE_TIMEOUT SHELLCHECK_OPTS LIM
  export LINT_JOBS=2
}
fail() { FAILS="$FAILS $1;"; }
expect() { [ "$2" = "$3" ] || fail "$1: want [$2] got [$3]"; }
guarded() { # guarded <seconds> cmd... : run in $R, stdout/stderr to $C/out,$C/err, set RC; a hang past the guard is a FAIL
  local lim=$1 pid g; shift
  printf x >> "$T/runs"; rm -f "$C/hung"
  [ "${TMPDIR:-}" != "$ORIG_TMPDIR" ] || export TMPDIR="$C/tmp" # the subject's workers then carry $C in their command lines
  set -m
  ( cd "$R" && exec "$@" ) > "$C/out" 2> "$C/err" &
  pid=$!
  set +m
  echo "$pid" >> "$FILES_LOG.pids"
  # the subject runs in its own process group: TERM it first (the tool's handler kills its workers), KILL the group after a grace
  ( trap 'kill $(jobs -p) 2>/dev/null; wait; exit 0' TERM; "$C/bin/sleep" "$lim" & wait $!; : > "$C/hung"; kill -TERM "$pid" 2>/dev/null; "$C/bin/sleep" 1 & wait $!; kill -KILL -- "-$pid" 2>/dev/null ) &  # MUT:guardkill
  g=$!; echo "$g" >> "$FILES_LOG.pids"
  wait "$pid"; RC=$?
  kill -TERM "$g" 2>/dev/null; wait "$g" 2>/dev/null
  [ ! -e "$C/hung" ] || fail "HUNG: killed by the ${lim}s guard"
}
lc() { guarded "${LIM:-$HARD}" env PATH="$C/bin:$ORIG_PATH" "$BASH_BIN" "$subject"; } # fake shellcheck first on PATH
lcr() { guarded "${LIM:-$HARD}" env PATH="$ORIG_PATH" "$BASH_BIN" "$subject"; }     # the REAL shellcheck
have_real() { command -v shellcheck >/dev/null || { SKIP="real shellcheck is not installed"; return 1; }; }
linted() { wc -l < "$FILES_LOG" | tr -d ' '; }
calls() { wc -l < "$FILES_LOG.argv" | tr -d ' '; }
sumline() { grep '^shellcheck:' "$C/out" | head -1; }
commit_all() { ( cd "$R" && git add -A && git commit -qm c ); }
sorted_log() { LC_ALL=C sort "$FILES_LOG" | tr '\n' ' '; }
rmfix() { rm "$R/a.sh" "$R/b.sh" "$R/dup.sh" "$R/sp ace/c d.sh"; }
physroot() { ( cd "$R" && pwd -P ); }
tmp_empty() { expect "$1" 0 "$(find "$2" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"; }
bgrun() { # start the subject in its own process group (so INT is deliverable) with env pairs; sets BGPID, BGG
  set -m
  ( cd "$R" && exec env TMPDIR="$C/tmp" "$@" PATH="$C/bin:$ORIG_PATH" "$BASH_BIN" "$subject" ) > "$C/out" 2> "$C/err" &
  BGPID=$!
  set +m
  echo "$BGPID" >> "$FILES_LOG.pids"
  printf x >> "$T/runs"; rm -f "$C/hung"
  ( trap 'kill $(jobs -p) 2>/dev/null; wait; exit 0' TERM; "$C/bin/sleep" 25 & wait $!; : > "$C/hung"; kill -TERM "$BGPID" 2>/dev/null; "$C/bin/sleep" 1 & wait $!; kill -KILL -- "-$BGPID" 2>/dev/null ) &
  BGG=$!; echo "$BGG" >> "$FILES_LOG.pids"
}
bgend() { wait "$BGPID"; RC=$?; kill -TERM "$BGG" 2>/dev/null; wait "$BGG" 2>/dev/null; [ ! -e "$C/hung" ] || fail "HUNG: killed by the 25s guard"; }
unrelated_sleep() { "$C/bin/sleep" 4423 & SIB=$!; echo "$SIB" >> "$FILES_LOG.pids"; }
end_unrelated() { kill -0 "$SIB" 2> /dev/null || fail "$1: an unrelated sibling sleep was killed"; kill -KILL "$SIB" 2> /dev/null; wait "$SIB" 2> /dev/null; }
LIBARR='#!/bin/bash\nARR=(1 2)\necho "${ARR[@]}"\n'
SRCSH='#!/bin/bash\n. ./lib.sh\necho "$ARR"\n'

# ---- fake cases: what is linted, and how ---------------------------------------------
t_cold_lints_each_real_file_once_and_remembers_nothing() {
  # a.sh and dup.sh are byte-identical REAL files: both are linted
  TMPDIR="$C/tmp" lc; expect rc 0 "$RC"
  expect lints 4 "$(linted)"
  expect summary "shellcheck: 4 real file(s) linted for 4 tracked path(s); 0 symlink(s) resolve to a file already linted; severity=warning" "$(sumline)"
  tmp_empty temp_dir_removed_on_exit "$C/tmp"
  : > "$FILES_LOG"; lc; expect second_run_lints_everything_again 4 "$(linted)"
}
t_identical_real_files_get_two_invocations() {
  # regression guard for four review rounds: no verdict is shared between different real files
  rm "$R/b.sh" "$R/sp ace/c d.sh"; commit_all
  lc; expect rc 0 "$RC"; expect lints 2 "$(linted)"; expect files "a.sh dup.sh " "$(sorted_log)"
  printf 'echo DIRTY\n' > "$R/a.sh"; printf 'echo DIRTY\n' > "$R/dup.sh"; lc; expect rc1 1 "$RC"
  grep -q '^In a.sh line 1' "$C/out" && grep -q '^In dup.sh line 1' "$C/out" || fail "both copies must report: $(cat "$C/out")"
}
t_findings_printed_under_the_real_path() {
  printf 'echo DIRTY\n' > "$R/b.sh"
  lc; expect rc1 1 "$RC"
  grep -q 'In b.sh line 1: finding' "$C/out" || fail "findings not printed"
  grep -q 'findings in 1 of 4 real file' "$C/err" || fail "no findings summary on stderr"
  grep -q 'also reachable' "$C/out" && fail "an also-reachable line without a link"
}
t_one_file_per_call_with_x() {
  lc; expect rc 0 "$RC"
  expect calls 4 "$(calls)"
  expect every_call_is_x_S_dashdash 0 "$(grep -vc -- '^-x -S warning -- ' "$FILES_LOG.argv")"
  grep -qx -- '-x -S warning -- sp ace/c d.sh' "$FILES_LOG.argv" || fail "spaced path not passed whole: $(cat "$FILES_LOG.argv")"
  : > "$FILES_LOG.argv"; LINT_SEVERITY=style lc; grep -q -- '-x -S style -- ' "$FILES_LOG.argv" || fail "severity not passed"
}
t_untracked_sh_is_not_linted() {
  printf 'echo DIRTY\n' > "$R/scratch.sh"; lc; expect rc 0 "$RC"
  expect lints 4 "$(linted)"
}
t_zero_tracked_sh_is_exit_2() {
  ( cd "$R" && git rm -q a.sh b.sh dup.sh "sp ace/c d.sh" && git commit -qm none )
  lc; expect rc 2 "$RC"
  grep -q 'ZERO shell scripts' "$C/err" || fail "no ZERO message"
}
t_shellcheck_missing_is_exit_2() {
  mkdir -p "$C/empty"
  guarded "$HARD" env PATH="$C/empty" "$BASH_BIN" "$subject"
  expect rc 2 "$RC"
  grep -q 'shellcheck missing' "$C/err" || fail "no missing message: $(cat "$C/err")"
}
t_exit_2_is_tool_error_and_beats_findings() {
  FAKE_DIRTY=a.sh FAKE_RC=2 FAKE_RC_ON=b.sh lc; expect rc 2 "$RC"
  grep -q "TOOL ERROR on b.sh: shellcheck exit '2' (not a finding): fake tool failure" "$C/err" || fail "the tool's first stderr line is not shown: $(cat "$C/err")"
  grep -q 'In a.sh line 1' "$C/out" || fail "the finding was lost behind the tool error"
  grep -q 'findings in' "$C/err" && fail "a tool error was reported as findings"
  FAKE_RC=1 FAKE_RC_ON=b.sh lc; expect exit_1_with_output_is_a_finding 1 "$RC"
  FAKE_KILL=b.sh lc; expect killed_rc 2 "$RC"
  grep -q 'TOOL ERROR on b.sh' "$C/err" || fail "a killed shellcheck is not a tool error"
}
t_output_is_identical_for_one_and_four_jobs() {
  local i; mkdir -p "$R/zz" "$R/mm"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do printf 'echo %s %s\n' "$i" "$([ $((i % 3)) = 0 ] && echo DIRTY)" > "$R/f$i.sh"; done
  for i in 1 2 3 4; do printf 'echo DIRTY %s\n' "$i" > "$R/zz/z$i.sh"; printf 'echo DIRTY m%s\n' "$i" > "$R/mm/m$i.sh"; done
  commit_all
  LINT_JOBS=1 lc; cp "$C/out" "$C/out1"; expect rc1 1 "$RC"
  LINT_JOBS=4 lc; cmp -s "$C/out1" "$C/out" || fail "stdout differs between LINT_JOBS=1 and 4"
  [ "$(grep -c '^In ' "$C/out")" = 12 ] || fail "expected 12 findings, got $(grep -c '^In ' "$C/out")"
  grep '^In ' "$C/out" | cut -d' ' -f2 > "$C/order"
  LC_ALL=C sort "$C/order" | cmp -s - "$C/order" || fail "findings are not in path order: $(tr '\n' ' ' < "$C/order")"
  LINT_JOBS=0 lc; expect jobs_0 2 "$RC"; LINT_JOBS=abc lc; expect jobs_abc 2 "$RC"; LINT_JOBS=-1 lc; expect jobs_neg 2 "$RC"
  LINT_FILE_TIMEOUT=0 lc; expect timeout_0 2 "$RC"; LINT_FILE_TIMEOUT=abc lc; expect timeout_abc 2 "$RC"
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
t_unreadable_file_is_exit_2() {
  rm "$R/b.sh"; lc; expect rc 2 "$RC"
  grep -q 'cannot read tracked file b.sh' "$C/err" || fail "no message naming the file: $(cat "$C/err")"
  expect nothing_linted 0 "$(linted)"
}

# ---- fake cases: symlinks (a tracked symlink IS its target) --------------------------------
t_symlink_to_tracked_script_is_one_invocation() {
  ln -s a.sh "$R/lnk.sh"; commit_all; printf 'echo DIRTY\n' > "$R/a.sh"
  lc; expect rc1 1 "$RC"
  expect lints 4 "$(linted)"; grep -qx 'lnk.sh' "$FILES_LOG" && fail "the link was linted as a script of its own"
  grep -q '^In a.sh line 1' "$C/out" || fail "finding not under the real path: $(cat "$C/out")"
  grep -q '^In lnk.sh' "$C/out" && fail "finding printed under the link"
  grep -qx 'also reachable as: lnk.sh' "$C/out" || fail "no also-reachable line: $(cat "$C/out")"
  expect summary "shellcheck: 4 real file(s) linted for 5 tracked path(s); 1 symlink(s) resolve to a file already linted; severity=warning" "$(sumline)"
}
t_nine_links_and_two_real_identical_files_are_two_invocations() {
  local i; rm "$R/b.sh" "$R/sp ace/c d.sh"
  for i in 1 2 3 4 5 6 7 8 9; do ln -s a.sh "$R/l$i.sh"; done; commit_all
  lc; expect rc 0 "$RC"; expect lints 2 "$(linted)"; expect files "a.sh dup.sh " "$(sorted_log)"
  expect summary "shellcheck: 2 real file(s) linted for 11 tracked path(s); 9 symlink(s) resolve to a file already linted; severity=warning" "$(sumline)"
}
t_symlink_chain() {
  ln -s a.sh "$R/l1.sh"; ln -s l1.sh "$R/l2.sh"; commit_all; printf 'echo DIRTY\n' > "$R/a.sh"
  lc; expect rc1 1 "$RC"; expect lints 4 "$(linted)"
  grep -qx 'also reachable as: l1.sh, l2.sh' "$C/out" || fail "chain not resolved to the file: $(cat "$C/out")"
}
t_relative_and_absolute_link_inside_the_repo() {
  mkdir "$R/sub"; ln -s ../a.sh "$R/sub/rel.sh"; ln -s "$(physroot)/b.sh" "$R/abs.sh"; commit_all
  printf 'echo DIRTY\n' > "$R/a.sh"; printf 'echo DIRTY\n' > "$R/b.sh"
  lc; expect rc1 1 "$RC"; expect lints 4 "$(linted)"
  grep -qx 'also reachable as: sub/rel.sh' "$C/out" || fail "relative link: $(cat "$C/out")"
  grep -qx 'also reachable as: abs.sh' "$C/out" || fail "absolute link: $(cat "$C/out")"
}
t_link_target_outside_the_repo_is_exit_2() {
  printf 'echo x\n' > "$C/outside.sh"; ln -s "$C/outside.sh" "$R/out.sh"; commit_all
  lc; expect rc_absolute 2 "$RC"
  grep -q '^lint: tracked link out.sh -> [^ ]* points outside the repository' "$C/err" || fail "link not named: $(cat "$C/err")"
  expect nothing_linted 0 "$(linted)"
  rm "$R/out.sh"; ln -s ../outside.sh "$R/out.sh"; commit_all; lc; expect rc_relative 2 "$RC"
}
t_dangling_link_is_exit_2() {
  ln -s nowhere.sh "$R/dang.sh"; commit_all
  lc; expect rc 2 "$RC"; grep -q '^lint: tracked link dang.sh: dangling (target ' "$C/err" || fail "not named as dangling: $(cat "$C/err")"
}
t_link_to_a_directory_is_exit_2() {
  mkdir "$R/adir"; printf 'x\n' > "$R/adir/f.txt"; ln -s adir "$R/dirlink.sh"; commit_all
  lc; expect rc 2 "$RC"; grep -q '^lint: tracked link dirlink.sh: target [^ ]* is a directory' "$C/err" || fail "not named as a directory link: $(cat "$C/err")"
}
t_link_to_an_untracked_in_repo_file_is_linted_with_a_note() {
  printf 'echo u\n' > "$R/untracked-target.txt"; ln -s untracked-target.txt "$R/u.sh"
  ( cd "$R" && git add u.sh && git commit -qm link )
  lc; expect rc 0 "$RC"
  grep -qx 'note: u.sh -> untracked-target.txt (target is not tracked)' "$C/err" || fail "no note: $(cat "$C/err")"
  expect summary "shellcheck: 5 real file(s) linted for 5 tracked path(s); 0 symlink(s) resolve to a file already linted; 1 symlink(s) lead to an untracked file, linted only through the link; severity=warning" "$(sumline)"
  grep -qx 'untracked-target.txt' "$FILES_LOG" || fail "the target was not linted: $(cat "$FILES_LOG")"
  grep -qx 'u.sh' "$FILES_LOG" && fail "the link itself was linted"
}
t_link_named_sh_whose_target_is_not() {
  printf 'echo DIRTY\n' > "$R/tool.bash"; ln -s tool.bash "$R/t.sh"; commit_all
  lc; expect rc1 1 "$RC"
  grep -qx 'tool.bash' "$FILES_LOG" || fail "the target was not linted: $(cat "$FILES_LOG")"
  grep -q '^In tool.bash' "$C/out" && grep -qx 'also reachable as: t.sh' "$C/out" || fail "no finding under the target: $(cat "$C/out")"
  grep -q '^note:' "$C/err" && fail "a tracked target got an untracked note"
}
t_links_in_any_creation_order_give_the_same_output() {
  printf 'echo DIRTY\n' > "$R/a.sh"
  ln -s a.sh "$R/lb.sh"; ln -s a.sh "$R/la.sh"; commit_all
  lc; cp "$C/out" "$C/out1"
  ( cd "$R" && git rm -q lb.sh la.sh && git commit -qm rm ); ln -s a.sh "$R/la.sh"; ln -s a.sh "$R/lb.sh"; commit_all
  lc; cmp -s "$C/out1" "$C/out" || fail "output depends on the order the links were made"
  grep -qx 'also reachable as: la.sh, lb.sh' "$C/out" || fail "links not listed in byte order: $(cat "$C/out")"
}

t_link_target_with_newline_or_tab_is_exit_2() {
  # readlink adds ONE newline: a name that ends in a newline, holds one, or holds a tab must not be cut or split
  local nl=$'\n' tab=$'\t' name v
  printf 'echo DIRTY\n' > "$R/x.sh$nl"; printf 'echo a\n' > "$R/a${nl}b"; printf 'echo t\n' > "$R/t${tab}x"; commit_all
  for v in "x.sh$nl" "a${nl}b" "t${tab}x"; do
    ln -s "$v" "$R/l.sh"; ( cd "$R" && git add l.sh && git commit -qm l ); name=$(printf %s "$v" | tr '\n\t' 'NT')
    lc; expect "rc_$name" 2 "$RC"
    grep -q '^lint: tracked link l.sh: a path on its way contains a newline or a tab' "$C/err" || fail "$name: link not refused by name: $(head -2 "$C/err")"
    ( cd "$R" && git rm -qf l.sh && git commit -qm r )
  done
}
t_hang_guard_kills_the_whole_group() {
  # the guard TERMs the subject, then KILLs its process group: a TERM-ignoring child must not be left behind
  printf '#!/bin/bash\ntrap "" TERM\n"%s/bin/sleep" 6123 &\nwait\n' "$C" > "$C/hang.sh"
  guarded 1 "$BASH_BIN" "$C/hang.sh"
  case $FAILS in *HUNG*) FAILS="" ;; *) fail "the guard did not fire" ;; esac
  sleep 0.3
  if pgrep -f "$C/sl 6123" > /dev/null; then fail "the guard left an orphan behind"; fi # MUT:hangpat
}
t_hang_guard_ignores_foreign_processes() {
  # a decoy TERM-immune `sleep 6123` that this run did not start: the hang case must neither match nor kill it
  local dp line
  bash -c 'trap "" TERM; exec sleep 6123' & dp=$!
  echo "$dp" >> "$C/foreign.pids"; sleep 0.2
  line=$(nested hang_guard_kills_the_whole_group)
  case $line in ok*) ;; *) fail "the hang case does not pass beside a foreign decoy: $line" ;; esac
  kill -0 "$dp" 2> /dev/null || fail "the hang case killed a process it did not own"
  kill -KILL "$dp" 2> /dev/null; wait "$dp" 2> /dev/null
}
t_reap_kills_term_immune_helpers() {
  local p
  # carries $T in its command line but is in no pid file: only the pgrep half of reap_all can find it
  bash -c 'trap "" TERM; exec -a "$1/imm" "$2" 6127' x "$C" "$REALSLEEP" & p=$!
  sleep 0.3
  reap_all
  if kill -0 "$p" 2> /dev/null; then fail "a TERM-immune helper survived reap_all"; kill -KILL "$p"; fi
  wait "$p" 2> /dev/null
}
t_leak_check_sees_a_helper_without_the_root_in_its_command_line() {
  local p out
  sleep 6128 & p=$!
  echo "$p" >> "$FILES_LOG.pids"
  out=$(leak_check)
  case " $out " in *" $p "*) ;; *) fail "leak_check missed pid $p: [$out]" ;; esac
  kill -KILL "$p" 2> /dev/null; wait "$p" 2> /dev/null
}
t_timeout_kills_the_whole_group_of_the_shellcheck() {
  # a fake shellcheck that spawns a child and ignores TERM: after the timeout nothing of this case survives
  local t0=$SECONDS
  FAKE_SPAWN=6129 LINT_FILE_TIMEOUT=1 lc; expect rc 2 "$RC"
  [ $((SECONDS - t0)) -lt 8 ] || fail "took $((SECONDS - t0)) s"
  grep -q 'timeout: b.sh' "$C/err" || fail "no timeout line: $(head -3 "$C/err")"
  grep -q 'TOOL ERROR' "$C/err" && fail "surfaced as a tool error"
  sleep 0.3; pgrep -f "$C/sl 6129" > /dev/null && fail "a child of the timed-out shellcheck survived"
}
t_link_loop_is_exit_2_promptly() {
  ln -s loop2.sh "$R/loop1.sh"; ln -s loop1.sh "$R/loop2.sh"; commit_all
  LIM=8 lc; expect rc 2 "$RC"
  grep -q '^lint: tracked link loop[12].sh: too many levels of symbolic links' "$C/err" || fail "no loop message: $(head -2 "$C/err")"
}
t_links_resolve_physically_not_logically() {
  # d -> sub/realdir, so `d/..` is sub; a logical reading would say the root
  mkdir -p "$R/sub/realdir"; printf 'echo y\n' > "$R/sub/y.txt"; printf 'echo decoy\n' > "$R/y.txt"
  ln -s sub/realdir "$R/d"; ln -s d/../y.txt "$R/l.sh"; commit_all
  lc; expect rc 0 "$RC"
  grep -qx 'sub/y.txt' "$FILES_LOG" && ! grep -qx 'y.txt' "$FILES_LOG" || fail "linted [$(sorted_log)] instead of sub/y.txt"
}

# ---- fake cases: process control ----------------------------------------------------------
t_term_removes_the_temp_dir() {
  # TERM removes the temp dir (SIGKILL cannot be handled and is not tested)
  mkfifo "$C/fifo"
  bgrun TMPDIR="$C/tmp" FAKE_FIFO="$C/fifo" FAKE_HOLD_ON=b.sh
  read -r _ < "$C/fifo"; kill -TERM "$BGPID"; bgend
  expect rc_143 143 "$RC"; tmp_empty temp_dir_removed "$C/tmp"
}
t_signals_kill_the_group_fast() {
  # 20 files at ~5 s each: TERM, INT and HUP end the run in < 3 s with the exit code of the
  # signal, leave no fake shellcheck behind (the absence of the marker process after one
  # bounded settle sleep), keep an unrelated sibling sleep alive, remove the temp dir
  local i sig code t0 nap=5.0731
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do printf 'echo %s\n' "$i" > "$R/g$i.sh"; done; commit_all
  for sig in TERM:143 INT:130 HUP:129; do
    code=${sig#*:}; sig=${sig%:*}; mkdir "$C/tmp.$sig"
    unrelated_sleep
    bgrun TMPDIR="$C/tmp.$sig" FAKE_NAP=$nap LINT_JOBS=4
    sleep 1; t0=$SECONDS; kill -"$sig" "$BGPID"; bgend
    expect "rc_$sig" "$code" "$RC"
    [ $((SECONDS - t0)) -lt 3 ] || fail "$sig: took $((SECONDS - t0)) s to exit"
    sleep 0.3
    pgrep -f "$C/sl $nap" > /dev/null && fail "$sig: a fake shellcheck survived"
    end_unrelated "$sig"; tmp_empty "temp_dir_removed_$sig" "$C/tmp.$sig"
  done
}
t_term_ignoring_shellcheck_is_killed_after_the_grace() {
  # a shellcheck that ignores TERM must not outlive the run: KILL after the grace
  local i t0 nap=5.0733
  for i in 1 2 3 4 5 6 7 8; do printf 'echo %s\n' "$i" > "$R/g$i.sh"; done; commit_all
  bgrun FAKE_NAP=$nap FAKE_IGNORE_TERM=1 LINT_JOBS=4
  sleep 1; t0=$SECONDS; kill -TERM "$BGPID"; bgend
  expect rc_143 143 "$RC"
  [ $((SECONDS - t0)) -lt 4 ] || fail "took $((SECONDS - t0)) s to exit"
  sleep 0.3
  pgrep -f "$C/sl $nap" > /dev/null && fail "a TERM-ignoring fake shellcheck survived the run (orphan)"
}
t_file_timeout_is_a_tool_error() {
  local t0=$SECONDS
  FAKE_HANG_ON=b.sh FAKE_HANG=3171 LINT_FILE_TIMEOUT=1 lc; expect rc 2 "$RC"
  [ $((SECONDS - t0)) -lt 15 ] || fail "took $((SECONDS - t0)) s for a 1 s timeout"
  grep -q 'timeout: b.sh' "$C/err" || fail "message does not name the file: $(cat "$C/err")"
  grep -q 'TOOL ERROR' "$C/err" && fail "the timeout surfaced as a tool error: $(cat "$C/err")"
  grep -q 'findings in' "$C/err" && fail "a timeout was reported as findings"
  sleep 0.3; pgrep -f "$C/sl 3171" > /dev/null && fail "the hung shellcheck survived"
}
t_watchdog_kills_a_term_ignoring_file() {
  local t0=$SECONDS
  FAKE_HANG_ON=b.sh FAKE_HANG=8.0517 FAKE_IGNORE_TERM=1 LINT_FILE_TIMEOUT=1 lc; expect rc 2 "$RC"
  [ $((SECONDS - t0)) -lt 6 ] || fail "the file was not killed after the grace: $((SECONDS - t0)) s"
  grep -q 'timeout: b.sh' "$C/err" || fail "no timeout line: $(cat "$C/err")"
  sleep 0.3; pgrep -f "$C/sl 8.0517" > /dev/null && fail "a TERM-ignoring shellcheck survived its watchdog"
}
t_watchdog_outcome_is_deterministic_at_the_boundary() {
  # 20 runs at once, each file napping ~ the timeout: only `clean` or `timeout`, never exit 137, never a lost file
  local i pids="" g bad=0 to=0 clean=0
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    ( cd "$R" && TMPDIR="$C/tmp" FAKE_NAP=1 LINT_FILE_TIMEOUT=1 LINT_JOBS=4 PATH="$C/bin:$ORIG_PATH" "$BASH_BIN" "$subject" > "$C/o.$i" 2> "$C/e.$i"; echo $? > "$C/r.$i" ) &
    pids="$pids $!"; printf x >> "$T/runs"
  done
  # shellcheck disable=SC2086
  ( trap 'kill $(jobs -p) 2>/dev/null; wait; exit 0' TERM; "$C/bin/sleep" 40 & wait $!; kill -KILL $pids 2>/dev/null ) &
  g=$!
  # shellcheck disable=SC2086
  wait $pids
  kill -TERM "$g" 2>/dev/null; wait "$g" 2>/dev/null
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    case $(cat "$C/r.$i" 2> /dev/null) in
      0) clean=$((clean + 1)); grep -q 'timeout' "$C/e.$i" && bad=$((bad + 1)) ;;
      2) to=$((to + 1)); grep -q 'timeout: ' "$C/e.$i" || bad=$((bad + 1)); grep -q 'TOOL ERROR' "$C/e.$i" && bad=$((bad + 1)) ;;
      *) bad=$((bad + 1)) ;;
    esac
  done
  expect bad_outcomes 0 "$bad"
  expect accounted_for 20 $((clean + to))
  sleep 1.1 # the napping fakes the watchdog TERMed finish their own `sleep 1`
}
t_no_watchdog_sleep_is_left_after_a_normal_run() {
  local tm=$((10000 + $$ % 50000)) # a marker no other process of this machine sleeps for
  LIM=10 LINT_FILE_TIMEOUT=$tm lc; expect rc 0 "$RC"
  sleep 0.3
  if pgrep -f "$C/sl $tm" > /dev/null; then fail "a watchdog sleep outlived the run: $(pgrep -fl "$C/sl $tm" | cut -c1-90 | tr '\n' '|')"; fi
}

# ---- real shellcheck ---------------------------------------------------------------
t_real_lib_change_flips_verdict() {
  # a.sh uses an array that lib.sh defines: followed with -x, SC2128 fires in a.sh; a change of
  # only lib.sh flips the verdict on the next run (nothing is remembered)
  have_real || return 0
  rmfix; printf '%b' "$SRCSH" > "$R/a.sh"; printf '%b' "$LIBARR" > "$R/lib.sh"; commit_all
  lcr; expect rc_array 1 "$RC"; grep -q 'SC2128' "$C/out" || fail "SC2128 not reported: $(head -5 "$C/out")"
  ( cd "$R" && shellcheck -S warning a.sh lib.sh > /dev/null 2>&1 ); expect old_recipe_rc 1 "$?"
  printf '#!/bin/bash\nARR=1\necho "$ARR"\n' > "$R/lib.sh"
  lcr; expect rc_scalar 0 "$RC"; expect summary "shellcheck: 2 real file(s) linted for 2 tracked path(s); 0 symlink(s) resolve to a file already linted; severity=warning" "$(sumline)"
  printf '%b' "$LIBARR" > "$R/lib.sh"
  lcr; expect rc_array_again 1 "$RC"
}
t_real_looser_than_the_old_recipe() {
  # a script sourcing a tracked NON-.sh file or an UNTRACKED file is followed and clean
  have_real || return 0
  rmfix; printf '#!/bin/bash\n. ./tracked.lib\n. ./untracked.lib\necho "$t1$t2"\n' > "$R/a.sh"
  printf 't1=1\n' > "$R/tracked.lib"; commit_all; printf 't2=2\n' > "$R/untracked.lib"
  lcr; expect rc_followed 0 "$RC"
  ( cd "$R" && shellcheck -S warning a.sh > /dev/null 2>&1 ); expect old_recipe_false_positive 1 "$?"
}
kw_setup() { # variant: the round-3/4 fixture. d1/x.sh and d2/x.sh are identical and source ./common.sh
  local v=$1 body
  rmfix; mkdir -p "$R/d1" "$R/d2"
  printf '#!/bin/bash\n. ./common.sh\necho "$ARR"\n' > "$R/d1/x.sh"; cp "$R/d1/x.sh" "$R/d2/x.sh"
  printf '#!/bin/bash\n# shellcheck disable=SC2034\nARR=1\n' > "$R/d1/lib.sh"
  printf '#!/bin/bash\n# shellcheck disable=SC2034\nARR=(1 2)\n' > "$R/d2/lib.sh"
  body="#!/bin/bash\n# shellcheck source-path=$SD\n. lib.sh\n"
  case $v in
    tracked) printf '%b' "$body" > "$R/common.sh"; commit_all ;;
    untracked) commit_all; printf '%b' "$body" > "$R/common.sh" ;;
    ignored) printf 'common.sh\n' > "$R/.gitignore"; printf '%b' "$body" > "$R/common.sh"; commit_all ;;
    binary) printf 'common.sh binary\n' > "$R/.gitattributes"; printf '%b' "$body" > "$R/common.sh"; commit_all ;;
    nul) { printf '%b' "$body"; printf '\0'; } > "$R/common.sh"; commit_all ;;
    symlink) mkdir "$R/real"; printf '%b' "$body" > "$R/real/common.txt"; ln -s real/common.txt "$R/common.sh"; commit_all ;;
  esac
}
t_real_directory_relative_source_path_variants() {
  # with no shared verdicts the copy in d2 follows ITS lib.sh whatever kind of file carries the keyword
  have_real || return 0
  local v
  for v in tracked untracked ignored binary nul symlink; do
    newcase "kw$v"; kw_setup "$v"
    lcr; expect "rc_$v" 1 "$RC"
    grep -q '^In d2/x.sh' "$C/out" || fail "$v: d2/x.sh finding lost: $(head -3 "$C/out")"
    grep -q '^In d1/x.sh' "$C/out" && fail "$v: d1/x.sh reported"
  done
}
t_real_link_in_another_directory_is_checked_as_its_real_path() {
  # PINNED DEFINITION (header): a symlinked script that sources directory-relatively is checked only against its
  # real directory's siblings. shellcheck resolves SCRIPTDIR from the path as given, so link/x.sh alone differs.
  have_real || return 0
  rmfix; mkdir -p "$R/real" "$R/link"
  printf '#!/bin/bash\n# shellcheck source-path=%s\n. ./lib.sh\necho "$v"\n' "$SD" > "$R/real/x.sh"
  printf '#!/bin/bash\n# shellcheck disable=SC2034\nv=1\n' > "$R/real/lib.sh"; printf '#!/bin/bash\n:\n' > "$R/link/lib.sh"
  ln -s ../real/x.sh "$R/link/x.sh"; commit_all
  ( cd "$R" && shellcheck -x -S warning -- link/x.sh > /dev/null 2>&1 ); expect link_path_alone_differs 1 "$?"
  lcr; expect rc_clean 0 "$RC"
  expect summary "shellcheck: 3 real file(s) linted for 4 tracked path(s); 1 symlink(s) resolve to a file already linted; severity=warning" "$(sumline)"
  printf 'for f in $(ls); do :; done\n' >> "$R/real/x.sh"
  lcr; expect rc_finding 1 "$RC"
  grep -q '^In real/x.sh' "$C/out" && grep -qx 'also reachable as: link/x.sh' "$C/out" || fail "finding not under real/x.sh with the link listed: $(head -4 "$C/out")"
}
rcf_supported() { # does the installed shellcheck take the abbreviated --rcf=?
  [ -z "${LINT_SELFTEST_FORCE_RCF:-}" ] || return 0
  local d="$C/probe"; mkdir -p "$d"; : > "$d/rc"; printf '#!/bin/bash\necho\n' > "$d/p.sh"
  shellcheck --rcf="$d/rc" -- "$d/p.sh" > /dev/null 2>&1
}
t_real_abbreviated_rcfile_option_is_honoured() {
  have_real || return 0
  if ! rcf_supported; then SKIP="this shellcheck does not accept --rcf="; return 0; fi # MUT:skip
  rmfix; mkdir -p "$R/d1" "$R/d2"
  printf '#!/bin/bash\n. lib.sh\necho "$ARR"\n' > "$R/d1/x.sh"; cp "$R/d1/x.sh" "$R/d2/x.sh"
  printf '#!/bin/bash\n# shellcheck disable=SC2034\nARR=1\n' > "$R/d1/lib.sh"; printf '#!/bin/bash\n# shellcheck disable=SC2034\nARR=(1 2)\n' > "$R/d2/lib.sh"
  commit_all
  printf 'source-path=%s\n' "$SD" > "$C/custom.rc"
  SHELLCHECK_OPTS="--rcf=$C/custom.rc" lcr; expect rc 1 "$RC"
  grep -q '^In d2/x.sh' "$C/out" || fail "d2/x.sh finding lost: $(head -3 "$C/out")"
  grep -q '^In d1/x.sh' "$C/out" && fail "d1/x.sh reported: the option was not applied"
}

# ---- the selftest's own skip logic -------------------------------------------------
nested() { # nested <case> <env...> : run this selftest on one case, print its first line
  local c=$1; shift
  mkdir -p "$T/nt"
  env TMPDIR="$T/nt" LINT_PARALLEL_SUBJECT="$subject" LINT_SELFTEST_ONLY="$c" "$@" "$BASH_BIN" "$SELF" 2> /dev/null | head -1
}
t_skip_logic_runs_the_case_when_the_probe_supports_it() {
  have_real || return 0
  local line
  line=$(nested real_abbreviated_rcfile_option_is_honoured LINT_SELFTEST_FORCE_RCF=1)
  case $line in SKIPPED*) fail "the probe was forced to report support and the case was still skipped: $line" ;; esac
  # nothing in the environment can force a skip: with the real probe, the case runs iff it is supported
  line=$(nested real_abbreviated_rcfile_option_is_honoured SKIP=1 SKIPPED=1 LINT_SKIP=1 LINT_SELFTEST_SKIP=1 CI=1)
  if rcf_supported; then case $line in SKIPPED*) fail "skipped though supported: $line" ;; esac
  else case $line in SKIPPED*) ;; *) fail "not skipped though unsupported: $line" ;; esac; fi
}
t_skips_are_counted_separately_from_ok() {
  # the installed shellcheck is hidden from PATH: the real cases skip, and the final line says "skipped", not "ok"
  local d="$C/nosc" tool out p
  mkdir -p "$d"
  for tool in cksum git awk grep tr mkdir cp rm cat head wc sort cmp find mktemp pgrep pkill sleep kill printf env uname date xargs mv chmod mkfifo dirname readlink cut ls getconf sed ln touch tail; do
    p=$(command -v "$tool") && ln -sf "$p" "$d/$tool"
  done
  mkdir -p "$T/nt"
  out=$(env TMPDIR="$T/nt" PATH="$d" LINT_PARALLEL_SUBJECT="$subject" LINT_SELFTEST_ONLY="real_lib_change_flips_verdict real_looser_than_the_old_recipe" "$BASH_BIN" "$SELF" 2> /dev/null)
  case $out in *"0 ok, 0 failed, 2 skipped"*) ;; *) fail "final line does not count skips apart: $(printf '%s' "$out" | tail -1)" ;; esac
  case $out in *"SKIPPED real_lib_change_flips_verdict: real shellcheck is not installed"*) ;; *) fail "no skip line with a reason: $out" ;; esac
}

CASES="cold_lints_each_real_file_once_and_remembers_nothing identical_real_files_get_two_invocations findings_printed_under_the_real_path one_file_per_call_with_x untracked_sh_is_not_linted zero_tracked_sh_is_exit_2 shellcheck_missing_is_exit_2 exit_2_is_tool_error_and_beats_findings output_is_identical_for_one_and_four_jobs odd_filenames unreadable_file_is_exit_2 symlink_to_tracked_script_is_one_invocation nine_links_and_two_real_identical_files_are_two_invocations symlink_chain relative_and_absolute_link_inside_the_repo link_target_outside_the_repo_is_exit_2 dangling_link_is_exit_2 link_to_a_directory_is_exit_2 link_to_an_untracked_in_repo_file_is_linted_with_a_note link_named_sh_whose_target_is_not links_in_any_creation_order_give_the_same_output link_target_with_newline_or_tab_is_exit_2 hang_guard_kills_the_whole_group hang_guard_ignores_foreign_processes reap_kills_term_immune_helpers leak_check_sees_a_helper_without_the_root_in_its_command_line timeout_kills_the_whole_group_of_the_shellcheck link_loop_is_exit_2_promptly links_resolve_physically_not_logically term_removes_the_temp_dir signals_kill_the_group_fast term_ignoring_shellcheck_is_killed_after_the_grace file_timeout_is_a_tool_error watchdog_kills_a_term_ignoring_file watchdog_outcome_is_deterministic_at_the_boundary no_watchdog_sleep_is_left_after_a_normal_run real_lib_change_flips_verdict real_looser_than_the_old_recipe real_directory_relative_source_path_variants real_link_in_another_directory_is_checked_as_its_real_path real_abbreviated_rcfile_option_is_honoured skip_logic_runs_the_case_when_the_probe_supports_it skips_are_counted_separately_from_ok"

one_case() {
  local n=$1 want="" lk
  newcase "$n"; FAILS=""; INFO=""; SKIP=""
  "t_$n"
  lk=$(leak_check); [ -z "$lk" ] || { fail "processes of this run outlived the case:$lk"; reap_all; }
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
    case $line in ok*) ok=$((ok + 1)) ;; SKIPPED*) skipped=$((skipped + 1)) ;; *) bad=$((bad + 1)) ;; esac # MUT:skipcount
  done
  line=$(leak_check)
  if [ -n "$line" ]; then bad=$((bad + 1)); printf 'FAIL leftover_processes: still alive:%s\n' "$line"; reap_all; fi
  printf '%s ok, %s failed, %s skipped (%s runs of the subject)\n' "$ok" "$bad" "$skipped" "$(wc -c < "$T/runs" | tr -d ' ')"
  [ "$total" -gt 0 ] || { echo "no case ran" >&2; exit 2; }
  [ "$bad" -eq 0 ]
}

# ---- mutations --------------------------------------------------------------------
# (the KILL escalation in the script's on_sig is defence in depth since each worker KILLs its shellcheck's own group on
#  TERM: removing it changes nothing observable, so it has no mutation entry here)
# subject mutations: id @@ marker=replacement line ('##' separates several) @@ guarding cases
MUTATIONS=$(cat <<'XEOF'
x-removed@@noxflag=X=@@one_file_per_call_with_x real_lib_change_flips_verdict
dashdash-removed@@dashdash=DD=@@one_file_per_call_with_x
realpath-resolution-removed@@realpath=  if false; then@@symlink_to_tracked_script_is_one_invocation nine_links_and_two_real_identical_files_are_two_invocations symlink_chain
sharing-reintroduced@@share=  h=$(cksum < "$rep" | tr -d ' '); if [[ "${SEEN:-}" == *"|$h|"* ]]; then L=$((L - 1)); continue; fi; SEEN="${SEEN:-}|$h|"; printf '%s\0%s\0' "$L" "$rep" >> "$T/lint.nul"@@identical_real_files_get_two_invocations cold_lints_each_real_file_once_and_remembers_nothing
out-of-repo-target-accepted@@outside=      *) rel=${REAL#"$root"/} ;;@@link_target_outside_the_repo_is_exit_2
dangling-accepted@@dangling=  [ -e "$p" ] || { REAL=$p; return 0; }@@dangling_link_is_exit_2
directory-target-accepted@@isdir=  :##notreg=  :@@link_to_a_directory_is_exit_2
also-reachable-dropped@@alsoprint=      :@@symlink_to_tracked_script_is_one_invocation symlink_chain
exit-ge2-mapped-to-findings@@rc1=    [1-9]*)@@exit_2_is_tool_error_and_beats_findings
exit-ge2-mapped-to-clean@@rc0=    0 | [2-9]* | 1[0-9][0-9])@@exit_2_is_tool_error_and_beats_findings
timeout-mapped-to-clean@@tomark=rc=0@@file_timeout_is_a_tool_error
timeout-marker-check-removed@@tomark=:@@file_timeout_is_a_tool_error watchdog_kills_a_term_ignoring_file
watchdog-kill-removed@@wdkill=  :@@watchdog_kills_a_term_ignoring_file
watchdog-kills-only-the-pid@@wdterm=  kill -TERM "$sc" 2>/dev/null##wdkill=  kill -KILL "$sc" 2>/dev/null@@timeout_kills_the_whole_group_of_the_shellcheck
readlink-trailing-newline-reverted@@rlnl=    t=$(readlink -- "$p") || { RERR="cannot read the link"; return 1; }##rlnl2=    :@@link_target_with_newline_or_tab_is_exit_2
real-path-newline-tab-check-removed@@nlcheck=    :@@link_target_with_newline_or_tab_is_exit_2
loop-cap-removed@@hopcap=    :@@link_loop_is_exit_2_promptly
physical-resolution-made-logical@@physical=    d=$(cd -- "$d" 2> /dev/null && pwd) || { RERR="x"; return 1; }@@links_resolve_physically_not_logically
watchdog-not-reaped@@wdreap=:@@no_watchdog_sleep_is_left_after_a_normal_run
group-kill-replaced-by-killing-xargs-only@@termkill=    kill -TERM "$xpid" 2> /dev/null##killesc=    :@@signals_kill_the_group_fast term_ignoring_shellcheck_is_killed_after_the_grace
output-sort-removed@@sortmap=cp "$T/map" "$T/map.sorted"@@symlink_to_tracked_script_is_one_invocation links_in_any_creation_order_give_the_same_output
untracked-files-linted@@gitls=find . -name '*.sh' -not -path './.git/*' -print0 > "$T/files0"@@untracked_sh_is_not_linted
zero-files-guard-removed@@zeroguard=  :@@zero_tracked_sh_is_exit_2
shellcheck-missing-guard-removed@@missing=:@@shellcheck_missing_is_exit_2
XEOF
)
# selftest mutations: applied to a copy of THIS file; the copy runs the guarding cases
SMUTATIONS=$(cat <<'XEOF'
hang-guard-kills-only-the-subject@@guardkill=  ( trap 'kill $(jobs -p) 2>/dev/null; wait; exit 0' TERM; "$C/bin/sleep" "$lim" & wait $!; : > "$C/hung"; kill -KILL "$pid" 2>/dev/null ) &@@hang_guard_kills_the_whole_group
hang-case-uses-a-global-pattern@@hangpat=  if pgrep -f "sleep 6123" > /dev/null; then fail "orphan"; fi@@hang_guard_ignores_foreign_processes
reap-uses-term-instead-of-kill@@reapkill=  for p in $(pgrep -f "$T"); do kill -TERM "$p" 2> /dev/null; done@@reap_kills_term_immune_helpers
end-check-reduced-to-pgrep-of-the-root@@leakpids=    for f in "$T"/none/*.pids; do@@leak_check_sees_a_helper_without_the_root_in_its_command_line
skip-made-unconditional@@skip=  if true; then SKIP="forced"; return 0; fi@@skip_logic_runs_the_case_when_the_probe_supports_it
skip-counted-as-ok@@skipcount=    case $line in ok*|SKIPPED*) ok=$((ok + 1)) ;; *) bad=$((bad + 1)) ;; esac@@skips_are_counted_separately_from_ok
XEOF
)
mutate_line() { # file id replacement
  local f=$1 id=$2 repl=$3
  REPL=$repl ID=$id awk '{ if (index($0, "# MUT:" ENVIRON["ID"]) && $0 ~ ("# MUT:" ENVIRON["ID"] "$")) print ENVIRON["REPL"]; else print }' "$f" > "$f.m" && mv "$f.m" "$f"
}
mutate_into() { # file spec: apply the '##'-separated marker=replacement pairs
  local rest=$2 pair mid repl
  while [ -n "$rest" ]; do
    case $rest in *'##'*) pair=${rest%%##*}; rest=${rest#*##} ;; *) pair=$rest; rest="" ;; esac
    mid=${pair%%=*}; repl=${pair#*=}
    mutate_line "$1" "$mid" "$repl"
  done
}
mutant_parses() { # does the mutant RUN through on a clean fixture without a shell syntax error?
  newcase mutctl; FAILS=""
  guarded 20 env LINT_FILE_TIMEOUT=1 PATH="$C/bin:$ORIG_PATH" "$BASH_BIN" "$1"
  ! grep -Eq 'syntax error|unexpected (token|EOF)' "$C/err"
}
run_mutations() {
  local line id spec cases d out red=0 green=0 base kind list surv=0 lk
  mkdir -p "$T/mut" "$T/nt"
  for kind in subject self; do
    if [ "$kind" = subject ]; then list=$MUTATIONS; else list=$SMUTATIONS; fi
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      id=${line%%@@*}; line=${line#*@@}; spec=${line%%@@*}; cases=${line#*@@}
      if [ -n "${LINT_MUT_ONLY:-}" ]; then case " $LINT_MUT_ONLY " in *" $id "*) ;; *) continue ;; esac; fi
      d="$T/mut/$id"; mkdir -p "$d"
      if [ "$kind" = subject ]; then
        cp "$subject" "$d/lint-parallel.sh"; mutate_into "$d/lint-parallel.sh" "$spec"
        if cmp -s "$subject" "$d/lint-parallel.sh"; then printf 'ERROR %-38s mutation did not change the script (marker missing?)\n' "$id"; green=$((green + 1)); continue; fi
        if ! mutant_parses "$d/lint-parallel.sh"; then printf 'ERROR %-38s mutant does not parse: %s\n' "$id" "$(grep -E 'syntax error|unexpected' "$C/err" | head -1)"; green=$((green + 1)); continue; fi
        out=$(TMPDIR="$T/nt" LINT_PARALLEL_SUBJECT="$d/lint-parallel.sh" LINT_SELFTEST_ONLY="$cases" "$BASH_BIN" "$SELF" 2>&1); base=$?
      else
        cp "$SELF" "$d/self.sh"; mutate_into "$d/self.sh" "$spec"
        if cmp -s "$SELF" "$d/self.sh"; then printf 'ERROR %-38s mutation did not change the selftest (marker missing?)\n' "$id"; green=$((green + 1)); continue; fi
        out=$(TMPDIR="$T/nt" LINT_PARALLEL_SUBJECT="$subject" LINT_SELFTEST_ONLY="$cases" "$BASH_BIN" "$d/self.sh" 2>&1); base=$?
      fi
      lk=$(leak_check); if [ -n "$lk" ]; then surv=$((surv + 1)); printf 'SURVIVORS after %s:%s\n' "$id" "$lk"; reap_all; fi
      if [ "$base" -eq 1 ]; then printf 'RED   %-38s %s\n' "$id" "$(printf '%s\n' "$out" | grep '^FAIL' | head -1 | cut -c1-110)"; red=$((red + 1))
      else printf 'GREEN %-38s the guarding case(s) [%s] still pass: that part is unguarded\n' "$id" "$cases"; green=$((green + 1)); fi
    done <<MUTEOF
$list
MUTEOF
  done
  printf '%s RED, %s not RED, %s mutant(s) left processes behind\n' "$red" "$green" "$surv"
  [ "$green" -eq 0 ] && [ "$surv" -eq 0 ]
}

if [ "${1:-}" = "--mutations" ]; then
  run_mutations
  exit $?
fi
run_cases
