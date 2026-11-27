#!/usr/bin/env bash
# lint-cached-selftest.sh -- proves scripts/lint-cached.sh is an honest cache.
#
# Hermetic and sequential: every case builds its own temp git repo and cache dir under
# one temp root. Two kinds of case:
#   fake cases  -- a FAKE `shellcheck` first on PATH logs every file it is asked to lint
#                  and calls a file "dirty" when its content contains the word DIRTY (or
#                  its path matches $FAKE_DIRTY); it can also exit with a chosen code or
#                  kill itself. They pin the cache machinery and are fast.
#   real cases  -- named real_*: the REAL shellcheck on small fixtures (cross-file
#                  sourcing, rc files). When shellcheck is not installed they are
#                  SKIPPED and the line says so; a skip is never a silent pass.
# One line per case, then "N ok, M failed". Exit 0 all ok, 1 any failure, 2 none ran.
#
# Usage: lint-cached-selftest.sh [--mutations]
#   --mutations  apply ONE mutation at a time to a scratch COPY of the subject (the
#                lines carrying a `# MUT:<id>` marker), run the cases that guard it, and
#                require RED. Prints RED/GREEN per mutation; exit 1 on any GREEN (that
#                part of the cache is unguarded).
# Env:   LINT_CACHE_SUBJECT  script under test (default ../lint-cached.sh)
#        LINT_SELFTEST_ONLY  space-separated case names (used by --mutations)
#        LINT_MUT_ONLY       space-separated mutation ids: run only those (and skip the
#                            baseline pass), to split a slow machine's run into chunks
set -uo pipefail

case ${BASH_SOURCE[0]} in */*) here=$(cd "${BASH_SOURCE[0]%/*}" && pwd) ;; *) here=$(pwd) ;; esac
subject=${LINT_CACHE_SUBJECT:-$here/../lint-cached.sh}
SELF="$here/${BASH_SOURCE[0]##*/}"
[ -r "$subject" ] || { echo "no subject at $subject" >&2; exit 2; }

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset LINT_CACHE LINT_CACHE_DIR LINT_JOBS LINT_BATCH LINT_SEVERITY SHELLCHECK_OPTS FAKE_DIRTY FAKE_RC FAKE_RC_ON FAKE_KILL XDG_CONFIG_HOME

T=$(mktemp -d "${TMPDIR:-/tmp}/lint-cache-selftest.XXXXXX") || exit 2
cleanup() { case $T in */lint-cache-selftest.*) rm -rf -- "$T" ;; esac; }
trap cleanup EXIT
BASH_BIN=$BASH
ORIG_PATH=$PATH
mkdir -p "$T/home"; export HOME="$T/home"

# ---- fixtures ---------------------------------------------------------------------
newcase() { # name -> C R CACHE FILES_LOG PROC_LOG; a repo with a, b, dup(=a), "sp ace/c d"
  C="$T/$1"; R="$C/repo"; CACHE="$C/cache"; FILES_LOG="$C/files"; PROC_LOG="$C/proc"
  mkdir -p "$R/sp ace" "$C/bin"; : > "$FILES_LOG"; : > "$PROC_LOG"
  export FILES_LOG PROC_LOG VER_FILE="$C/ver"; printf 'version: 1.0\n' > "$C/ver"
  cat > "$C/bin/shellcheck" <<'FAKE'
#!/bin/sh
printf 'shellcheck %s\n' "$*" >> "$PROC_LOG"
if [ "$1" = --version ]; then cat "$VER_FILE"; exit 0; fi
printf '%s\n' "$*" >> "$FILES_LOG.argv"
for a in "$@"; do f=$a; done
sev=$3
printf '%s\n' "$f" >> "$FILES_LOG"
[ -z "${FAKE_SLEEP:-}" ] || sleep "0.0$(( $$ % 4 ))"
if [ -n "${FAKE_KILL:-}" ]; then case $f in *"$FAKE_KILL"*) kill -9 $$ ;; esac; fi
if [ -n "${FAKE_RC:-}" ]; then case $f in *"${FAKE_RC_ON:-}"*) echo "fake tool failure"; exit "$FAKE_RC" ;; esac; fi
dirty=0
while IFS= read -r l || [ -n "$l" ]; do case $l in *DIRTY*) dirty=1 ;; esac; done < "$f"
[ -z "${FAKE_DIRTY:-}" ] || case $f in *"$FAKE_DIRTY"*) dirty=1 ;; esac
if [ "$dirty" = 1 ]; then echo "In $f line 1: finding (severity $sev)"; exit 1; fi
exit 0
FAKE
  chmod +x "$C/bin/shellcheck"
  if [ ! -d "$T/tmpl" ]; then
    mkdir -p "$T/tmpl/sp ace"
    printf 'echo a\n' > "$T/tmpl/a.sh"; printf 'echo b\n' > "$T/tmpl/b.sh"; printf 'echo a\n' > "$T/tmpl/dup.sh"
    printf 'echo c\n' > "$T/tmpl/sp ace/c d.sh"; printf 'text\n' > "$T/tmpl/readme.txt"
    ( cd "$T/tmpl" && git init -q . && git add -A && git commit -qm init )
  fi
  rm -rf -- "$R"; cp -R "$T/tmpl" "$R"
  unset FAKE_DIRTY FAKE_RC FAKE_RC_ON FAKE_KILL FAKE_SLEEP LINT_CACHE LINT_JOBS LINT_SEVERITY SHELLCHECK_OPTS
  export LINT_CACHE_DIR="$CACHE" LINT_JOBS=2
}
lc() { # run the subject inside the repo with the fake first on PATH
  ( cd "$R" && PATH="$C/bin:$ORIG_PATH" "$BASH_BIN" "$subject" ) > "$C/out" 2> "$C/err"; RC=$?
}
lcr() { # the same with the REAL shellcheck
  ( cd "$R" && PATH="$ORIG_PATH" "$BASH_BIN" "$subject" ) > "$C/out" 2> "$C/err"; RC=$?
}
have_real() { command -v shellcheck >/dev/null || { INFO="SKIPPED: real shellcheck is not installed"; return 1; }; }
linted() { wc -l < "$FILES_LOG" | tr -d ' '; }
reset() { : > "$FILES_LOG"; : > "$FILES_LOG.argv"; : > "$PROC_LOG"; }
sumline() { grep '^shellcheck:' "$C/out" | head -1; }
commit_all() { ( cd "$R" && git add -A && git commit -qm c ); }
fail() { FAILS="$FAILS $1;"; }
expect() { # label want got
  [ "$2" = "$3" ] || fail "$1: want [$2] got [$3]"
}
entries() { local n=0 f; for f in "$CACHE"/*; do [ ! -e "$f" ] && [ ! -L "$f" ] || n=$((n + 1)); done; echo "$n"; }
sorted_log() { LC_ALL=C sort "$FILES_LOG" | tr '\n' ' '; }
SUM0="shellcheck: 3 unique script(s) of 4 clean at severity=warning (cached 0, linted 3; sourcing 0)"
SUM3="shellcheck: 3 unique script(s) of 4 clean at severity=warning (cached 3, linted 0; sourcing 0)"
LOOP_DIRTY='#!/bin/bash\nfor f in $(ls); do echo "$f"; done\n' # real finding SC2045

# ---- cases ------------------------------------------------------------------------
t_cold_lints_each_unique_once() {
  lc; expect rc 0 "$RC"
  expect lints 3 "$(linted)"
  expect summary "$SUM0" "$(sumline)"
  expect entries 3 "$(entries)"
}
t_warm_invokes_shellcheck_zero_times() {
  lc; reset; lc; expect rc 0 "$RC"
  expect lints 0 "$(linted)"
  expect argv_calls 0 "$(wc -l < "$FILES_LOG.argv" | tr -d ' ')"
  expect summary "$SUM3" "$(sumline)"
}
t_edit_relints_exactly_that_content() {
  lc; reset; printf 'echo b2\n' > "$R/b.sh"   # unstaged edit of a tracked file
  lc; expect rc 0 "$RC"
  expect lints 1 "$(linted)"
  expect which b.sh "$(cat "$FILES_LOG")"
  expect summary "shellcheck: 3 unique script(s) of 4 clean at severity=warning (cached 2, linted 1; sourcing 0)" "$(sumline)"
}
t_identical_content_linted_once() {
  rm "$R/b.sh" "$R/sp ace/c d.sh"; commit_all   # a.sh and dup.sh remain, byte-identical, same dir
  lc; expect rc 0 "$RC"
  expect lints 1 "$(linted)"
  expect which a.sh "$(cat "$FILES_LOG")"
  expect summary "shellcheck: 1 unique script(s) of 2 clean at severity=warning (cached 0, linted 1; sourcing 0)" "$(sumline)"
}
t_dirty_file_is_never_cached() {
  printf 'echo DIRTY\n' > "$R/b.sh"
  lc; expect rc1 1 "$RC"
  grep -q 'In b.sh line 1: finding' "$C/out" || fail "findings not printed"
  expect entries1 2 "$(entries)"
  reset; lc; expect rc2 1 "$RC"
  expect relint_dirty_only b.sh "$(cat "$FILES_LOG")"
  grep -q 'In b.sh line 1: finding' "$C/out" || fail "findings not printed on 2nd run"
  grep -q 'findings in 1 of 3 unique' "$C/err" || fail "no findings summary on stderr"
  # two paths with one key: the finding is printed for the first, the other is listed
  printf 'echo DIRTY\n' > "$R/a.sh"; printf 'echo DIRTY\n' > "$R/dup.sh"; printf 'echo b\n' > "$R/b.sh"; lc
  grep -q 'In a.sh line 1' "$C/out" || fail "finding not under the representative a.sh"
  grep -q 'In dup.sh' "$C/out" && fail "finding printed under the non-representative dup.sh"
  grep -q 'the same verdict holds for dup.sh' "$C/out" || fail "sharing paths not listed: $(cat "$C/out")"
}
t_fixing_a_dirty_file_makes_it_clean_and_cached() {
  printf 'echo DIRTY\n' > "$R/b.sh"; lc
  printf 'echo fixed\n' > "$R/b.sh"; reset; lc; expect rc 0 "$RC"
  expect lints 1 "$(linted)"
  reset; lc; expect lints_after 0 "$(linted)"
  expect summary "$SUM3" "$(sumline)"
}
t_one_file_per_call_with_x() {
  # was: batches of LINT_BATCH files and a "re-run each alone" step; now ONE file per
  # call, always with -x (a batched call changed verdicts: a sourced file on the same
  # command line was followed, one that was not, was not)
  LINT_CACHE=off lc; expect rc 0 "$RC"
  expect calls 3 "$(wc -l < "$FILES_LOG.argv" | tr -d ' ')"
  expect one_path_per_call "$(linted)" "$(wc -l < "$FILES_LOG.argv" | tr -d ' ')"
  expect every_call_is_x_S_dashdash 0 "$(grep -vc -- '^-x -S warning -- ' "$FILES_LOG.argv")"
  grep -qx -- '-x -S warning -- sp ace/c d.sh' "$FILES_LOG.argv" || fail "spaced path not passed whole: $(cat "$FILES_LOG.argv")"
}
t_dirty_file_does_not_block_others_being_recorded() {
  # was batch_mates_...: a dirty file must not stop its neighbours being recorded clean
  printf 'echo DIRTY\n' > "$R/b.sh"; export LINT_JOBS=1
  lc; expect rc 1 "$RC"
  expect entries 2 "$(entries)"
  reset; lc; expect relint b.sh "$(cat "$FILES_LOG")"
}
t_untracked_sh_is_not_linted() {
  lc; printf 'echo DIRTY\n' > "$R/scratch.sh"; reset; lc; expect rc 0 "$RC"
  expect lints 0 "$(linted)"
  expect summary "$SUM3" "$(sumline)"
}
t_shellcheck_version_change_relints_all() {
  lc; printf 'version: 2.0\n' > "$VER_FILE"; reset; lc; expect rc 0 "$RC"
  expect lints 3 "$(linted)"
  expect summary "$SUM0" "$(sumline)"
}
t_severity_change_relints_all() {
  lc; reset; LINT_SEVERITY=style lc; expect rc 0 "$RC"
  expect lints 3 "$(linted)"
  grep -q -- '-S style' "$FILES_LOG.argv" || fail "severity not passed to shellcheck"
  expect summary "shellcheck: 3 unique script(s) of 4 clean at severity=style (cached 0, linted 3; sourcing 0)" "$(sumline)"
}
t_shellcheckrc_change_relints_all() {
  printf 'disable=SC2086\n' > "$R/.shellcheckrc"; commit_all; lc
  reset; lc; expect warm 0 "$(linted)"
  printf 'disable=SC2046\n' > "$R/.shellcheckrc"; reset; lc
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
  grep -q 'shellcheck missing' "$C/err" || fail "no missing message"
}
t_cache_off_lints_all_but_still_stores() {
  LINT_CACHE=off lc; expect rc 0 "$RC"; expect lints 3 "$(linted)"
  reset; lc; expect warm_after_off 0 "$(linted)"
  reset; LINT_CACHE=off lc; expect off_again 3 "$(linted)"
  expect summary "$SUM0" "$(sumline)"
}
t_verify_mode_relints_and_catches_a_lie() {
  lc; reset; LINT_CACHE=verify lc; expect rc_honest 0 "$RC"
  expect relinted 3 "$(linted)"
  grep -q 'verified 3 cached' "$C/out" || fail "no verified count: $(sumline)"
  reset; FAKE_DIRTY=b.sh LINT_CACHE=verify lc
  expect rc_lie 3 "$RC"
  grep -q 'CACHE LIE' "$C/err" || fail "no CACHE LIE message"
  expect entries_after 2 "$(entries)"
}
t_cache_dir_not_a_directory_is_exit_2() {
  # was corrupt_cache_dir_warns_and_lints_all (a file as cache dir: warning, lint all
  # uncached, exit 0); now refused with exit 2 and nothing linted
  : > "$C/notadir"; export LINT_CACHE_DIR="$C/notadir"
  lc; expect rc 2 "$RC"; expect lints 0 "$(linted)"
  grep -q 'refusing' "$C/err" || fail "no refusal message: $(cat "$C/err")"
}
t_cache_dir_symlink_is_exit_2() {
  mkdir -p "$C/real"; ln -s "$C/real" "$C/link"; export LINT_CACHE_DIR="$C/link"
  lc; expect rc 2 "$RC"; expect lints 0 "$(linted)"
  expect nothing_written 0 "$(find "$C/real" -mindepth 1 | wc -l | tr -d ' ')"
}
t_output_is_identical_for_one_and_four_jobs() {
  local i; mkdir -p "$R/zz" "$R/mm"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do printf 'echo %s %s\n' "$i" "$([ $((i % 3)) = 0 ] && echo DIRTY)" > "$R/f$i.sh"; done
  for i in 1 2 3 4; do printf 'echo DIRTY %s\n' "$i" > "$R/zz/z$i.sh"; printf 'echo DIRTY m%s\n' "$i" > "$R/mm/m$i.sh"; done
  commit_all; export FAKE_SLEEP=1
  LINT_CACHE=off LINT_JOBS=1 lc; cp "$C/out" "$C/out1"; expect rc1 1 "$RC"
  LINT_CACHE=off LINT_JOBS=4 lc; cmp -s "$C/out1" "$C/out" || fail "stdout differs between LINT_JOBS=1 and 4"
  [ "$(grep -c '^In ' "$C/out")" = 12 ] || fail "expected 12 findings, got $(grep -c '^In ' "$C/out")"
  LINT_CACHE=off LINT_JOBS=3 lc; cmp -s "$C/out1" "$C/out" || fail "stdout differs for LINT_JOBS=3"
  grep '^In ' "$C/out" | cut -d' ' -f2 > "$C/order"
  LC_ALL=C sort "$C/order" | cmp -s - "$C/order" || fail "findings are not in path order: $(tr '\n' ' ' < "$C/order")"
}
t_paths_with_spaces() {
  lc; grep -qx 'sp ace/c d.sh' "$FILES_LOG" || fail "spaced path not linted: $(cat "$FILES_LOG")"
  reset; lc; expect warm 0 "$(linted)"
  printf 'echo DIRTY\n' > "$R/sp ace/c d.sh"; lc; expect rc 1 "$RC"
  grep -q 'In sp ace/c d.sh line 1' "$C/out" || fail "spaced finding not printed"
}
t_odd_filenames() {
  printf 'echo bs\n' > "$R/back\\slash.sh"; printf 'echo dash\n' > "$R/-dash.sh"; commit_all
  lc; expect rc 0 "$RC"
  grep -qxF 'back\slash.sh' "$FILES_LOG" || fail "backslash path not linted whole: $(cat "$FILES_LOG")"
  grep -qxF -- '-dash.sh' "$FILES_LOG" || fail "dash path not linted whole"
  expect entries 5 "$(entries)"
  reset; lc; expect warm 0 "$(linted)"
  printf 'echo DIRTY\n' > "$R/back\\slash.sh"; lc; expect rc_dirty 1 "$RC"
  grep -qF 'In back\slash.sh line 1' "$C/out" || fail "backslash finding not printed: $(cat "$C/out")"
  rm "$R/back\\slash.sh"; commit_all
  printf 'echo t\n' > "$R/tab"$'\t'"x.sh"; commit_all; lc; expect rc_tab 2 "$RC"
  rm "$R/tab"$'\t'"x.sh"; commit_all
  if printf 'echo n\n' > "$R/nl"$'\n'"x.sh" 2> /dev/null; then
    commit_all; lc; expect rc_newline 2 "$RC"
    grep -q 'newline or a tab' "$C/err" || fail "no refusal message for the newline path"
  else INFO="newline filename not creatable here; refusal not exercised"; fi
}
mkproc() { # dir count: a repo of <count> distinct scripts, wrappers counting every external process
  local i
  for i in $(seq 1 "$2"); do printf 'echo %s\n' "$i" > "$R/g$i.sh"; done
  commit_all
  [ -d "$T/wrap" ] || { # built once: the wrappers read $PROC_LOG at run time
    mkdir -p "$T/wrap"; local t real
    for t in git xargs shasum sha256sum awk sort cat ls tr cut mkdir mv grep head rm mktemp cp date sed uname dirname getconf sysctl wc seq find; do
      real=$(PATH=$ORIG_PATH command -v "$t") || continue
      printf '#!/bin/sh\necho %s >> "$PROC_LOG"\nexec %s "$@"\n' "$t" "$real" > "$T/wrap/$t"; chmod +x "$T/wrap/$t"
    done
  }
}
proc_count() { # warm run under the wrappers -> number of external processes
  lc; reset
  ( cd "$R" && PATH="$T/wrap:$C/bin:$ORIG_PATH" "$BASH_BIN" "$subject" ) > "$C/out" 2> "$C/err"; RC=$?
  expect rc 0 "$RC"; expect lints 0 "$(linted)"
  wc -l < "$PROC_LOG" | tr -d ' '
}
t_all_cached_process_count_is_constant() {
  local n20 n400 root=$C
  mkproc "$C" 20; n20=$(proc_count)
  newcase proc150; mkproc "$C" 150; n400=$(proc_count)
  expect same_count "$n20" "$n400"
  [ "$n20" -gt 0 ] && [ "$n20" -le 40 ] || fail "process count $n20 outside 1..40"
  INFO="$n20 processes at 20 and at 150 files"; : "$root"
}
SRCSH='#!/bin/bash\n. ./lib.sh\necho "$ARR"\n'
t_sourcing_file_relinted_when_lib_changes() {
  printf '%b' "$SRCSH" > "$R/s.sh"; printf 'ARR=1\n' > "$R/lib.sh"; commit_all
  lc; expect rc 0 "$RC"
  expect summary "shellcheck: 5 unique script(s) of 6 clean at severity=warning (cached 0, linted 5; sourcing 1)" "$(sumline)"
  reset; lc; expect warm 0 "$(linted)"
  printf 'ARR=2\n' > "$R/lib.sh"; reset; lc
  expect relinted "lib.sh s.sh " "$(sorted_log)"   # lib.sh: its content changed; s.sh: only its SOURCE changed
  printf 'echo new\n' > "$R/a.sh"; reset; lc
  expect any_edit_relints_the_sourcer_too "a.sh s.sh " "$(sorted_log)"   # coarse on purpose: a sourced file may be any tracked *.sh
}
t_source_variants_are_classed_sourcing() {
  # every form the real shellcheck follows (measured, 0.11.0) must be a SOURCING file;
  # forms it does not follow may be either (over-matching only costs a cache hit);
  # a file that cannot source must stay out of it
  local i=0 v exp="lib.sh"
  rm -f "$R"/*.sh; printf 'ARR=1\n' > "$R/lib.sh"
  while IFS= read -r v; do
    i=$((i + 1)); printf '#!/bin/bash\n%b\necho "$ARR"\n' "$v" > "$R/p$i.sh"; exp="$exp p$i.sh"
  done <<'EOF'
. ./lib.sh
source ./lib.sh
\\. ./lib.sh
>/dev/null . ./lib.sh
2>/dev/null . ./lib.sh
. 2>/dev/null ./lib.sh
FOO=1 . ./lib.sh
if . ./lib.sh; then :; fi
true && . ./lib.sh
{ . ./lib.sh; }
x=$(. ./lib.sh)
.\\\n ./lib.sh
sou\\\nrce ./lib.sh
. "$PWD/lib.sh"
.\t./lib.sh
# shellcheck source=lib.sh\n. "$X"
echo x # shellcheck source=lib.sh
EOF
  i=0
  while IFS= read -r v; do
    i=$((i + 1)); printf '#!/bin/bash\n%b\n' "$v" > "$R/n$i.sh"
  done <<'EOF'
# the source of truth is lib.sh . here
sou""rce ./lib.sh
ls . | wc -l
cp a .
echo "v1.5"
EOF
  commit_all; lc; expect rc 0 "$RC"
  reset; printf 'ARR=2\n' > "$R/lib.sh"; lc
  expect relinted "$(printf '%s\n' $exp | LC_ALL=C sort | tr '\n' ' ')" "$(sorted_log)"
}
t_sourcing_key_includes_directory() {
  # a relative source resolves against the file's directory: identical sourcing content in
  # two directories is two keys; identical NON-sourcing content in two directories is one
  mkdir -p "$R/d1" "$R/d2" "$R/x" "$R/y"
  rm "$R/a.sh" "$R/b.sh" "$R/dup.sh" "$R/sp ace/c d.sh"
  printf '%b' "$SRCSH" > "$R/d1/s.sh"; printf '%b' "$SRCSH" > "$R/d2/s.sh"
  printf 'echo n\n' > "$R/x/n.sh"; printf 'echo n\n' > "$R/y/n.sh"; commit_all
  lc; expect rc 0 "$RC"
  expect lints 3 "$(linted)"
  expect summary "shellcheck: 3 unique script(s) of 4 clean at severity=warning (cached 0, linted 3; sourcing 2)" "$(sumline)"
}
t_rc_chain_nearest_wins() {
  mkdir -p "$R/sub" "$R/sub2"; printf 'echo n\n' > "$R/sub/n.sh"; printf 'echo q\n' > "$R/sub2/q.sh"
  printf 'disable=SC1000\n' > "$R/.shellcheckrc"; printf 'disable=SC2000\n' > "$R/sub/.shellcheckrc"; commit_all
  lc; expect rc 0 "$RC"; expect cold 5 "$(linted)"
  printf 'disable=SC1001\n' > "$R/.shellcheckrc"; reset; lc
  expect root_rc_changed_shadowed_dir_kept "a.sh b.sh sp ace/c d.sh sub2/q.sh " "$(sorted_log)"
  printf 'disable=SC2001\n' > "$R/sub/.shellcheckrc"; reset; lc
  expect nearest_rc_changed "sub/n.sh " "$(sorted_log)"
  printf 'disable=SC2002\n' > "$R/sub/shellcheckrc"; reset; lc          # the undotted name counts too
  expect undotted_rc "sub/n.sh " "$(sorted_log)"
  mkdir "$R/sub2/.shellcheckrc"; reset; lc                               # a directory of that name is skipped
  expect dir_named_rc_ignored 0 "$(linted)"
}
t_rc_chain_untracked_nested_and_ancestor() {
  mkdir -p "$R/sub"; printf 'echo n\n' > "$R/sub/n.sh"; commit_all
  lc; reset
  printf 'disable=SC2000\n' > "$R/sub/.shellcheckrc"; lc           # untracked, nested
  expect untracked_nested_relints_its_dir "sub/n.sh " "$(sorted_log)"
  rm "$R/sub/.shellcheckrc"; reset; lc
  expect removing_it_restores_the_old_key 0 "$(linted)"
  printf 'disable=SC2000\n' > "$C/.shellcheckrc"; reset; lc          # above the repo root
  expect ancestor_above_root_relints_all 4 "$(linted)"
  rm "$C/.shellcheckrc"; reset; lc; expect ancestor_removed 0 "$(linted)"
}
forge_prep() { # one-file repo, cold run, K = the entry's key
  ( cd "$R" && git rm -q a.sh dup.sh "sp ace/c d.sh" && git commit -qm one ); lc
  KEYNAME=""; local f; for f in "$CACHE"/*; do KEYNAME=${f##*/}; done
  expect one_entry 1 "$(entries)"
}
t_forged_entries_are_ignored() {
  forge_prep; reset
  # control: the genuine entry is trusted (so the forgeries below are not vacuous)
  FAKE_DIRTY=b.sh lc; expect control_genuine_entry_hits 0 "$RC"; expect control_lints 0 "$(linted)"
  local kind e="$CACHE/$KEYNAME"
  for kind in empty dir dangling wrongcontent extralines; do
    rm -rf "$e"
    case $kind in
      empty) : > "$e" ;;
      dir) mkdir "$e" ;;
      dangling) ln -s "$C/nowhere" "$e" ;;
      wrongcontent) printf 'lint-ok %s\n' "0000" > "$e" ;;
      extralines) printf 'lint-ok %s\nsecond\n' "$KEYNAME" > "$e" ;;
    esac
    reset; FAKE_DIRTY=b.sh lc
    expect "forged_${kind}_rc" 1 "$RC"; expect "forged_${kind}_relinted" 1 "$(linted)"
  done
  rm -rf "$e"; printf 'lint-ok %s\n' "$KEYNAME" > "$C/real.txt"; ln -s "$C/real.txt" "$e"        # a symlink, even to a file
  reset; FAKE_DIRTY=b.sh lc; expect forged_symlink_rc 1 "$RC"
}
t_shellcheck_exit_2_is_tool_error() {
  FAKE_RC=2 FAKE_RC_ON=b.sh lc; expect rc 2 "$RC"
  grep -q 'TOOL ERROR on b.sh' "$C/err" || fail "no tool-error message: $(cat "$C/err")"
  grep -q 'findings in' "$C/err" && fail "a tool error was reported as findings"
  expect only_the_healthy_files_cached 2 "$(entries)"
  reset; lc; expect rc_after 0 "$RC"; expect only_b_relinted "b.sh" "$(cat "$FILES_LOG")"
}
t_killed_shellcheck_is_tool_error() {
  FAKE_KILL=b.sh lc; expect rc 2 "$RC"
  grep -q 'TOOL ERROR on b.sh' "$C/err" || fail "no tool-error message: $(cat "$C/err")"
  expect only_the_healthy_files_cached 2 "$(entries)"
}
t_script_hash_is_in_the_key() {
  lc; reset
  cp "$subject" "$C/copy.sh"; printf '\n# edited copy\n' >> "$C/copy.sh"
  ( cd "$R" && PATH="$C/bin:$ORIG_PATH" "$BASH_BIN" "$C/copy.sh" ) > "$C/out" 2> "$C/err"; RC=$?
  expect rc 0 "$RC"; expect copy_does_not_reuse_entries 3 "$(linted)"
}
t_no_tmp_left_in_cache() {
  lc; expect rc 0 "$RC"
  local f n=0; for f in "$CACHE"/.tmp*; do [ ! -e "$f" ] || n=$((n + 1)); done
  expect tmp_leftovers 0 "$n"
  expect only_hidden_none 3 "$(find "$CACHE" -mindepth 1 | wc -l | tr -d ' ')"
}
# ---- real shellcheck ---------------------------------------------------------------
LIBARR='#!/bin/bash\nARR=(1 2)\necho "${ARR[@]}"\n'
t_real_shellcheck_basic() {
  have_real || return 0
  printf '#!/bin/sh\necho ok\n' > "$R/a.sh"; printf '%b' "$LOOP_DIRTY" > "$R/b.sh"
  rm "$R/dup.sh" "$R/sp ace/c d.sh"; commit_all
  lcr; expect rc 1 "$RC"; grep -q SC2045 "$C/out" || fail "real finding SC2045 not printed"
  expect entries 1 "$(entries)"
  printf '#!/bin/sh\necho fine\n' > "$R/b.sh"
  lcr; expect rc_fixed 0 "$RC"; expect summary "shellcheck: 2 unique script(s) of 2 clean at severity=warning (cached 1, linted 1; sourcing 0)" "$(sumline)"
}
t_real_src_repro() {
  # a.sh uses an array that lib.sh defines. Followed (-x), SC2128 fires in a.sh, whether or not
  # lib.sh is also on the command line; the old recipe (all files on one line) saw it too.
  have_real || return 0
  rm "$R/a.sh" "$R/b.sh" "$R/dup.sh" "$R/sp ace/c d.sh"
  printf '%b' "$SRCSH" > "$R/a.sh"; printf '%b' "$LIBARR" > "$R/lib.sh"; commit_all
  lcr; expect rc 1 "$RC"; grep -q 'SC2128' "$C/out" || fail "SC2128 not reported: $(head -5 "$C/out")"
  lcr; expect rc_warm 1 "$RC"; grep -q 'SC2128' "$C/out" || fail "SC2128 not reported on the warm run"
  ( cd "$R" && shellcheck -S warning a.sh lib.sh > /dev/null 2>&1 ); expect old_recipe_rc 1 "$?"
}
t_real_lib_change_flips_verdict() {
  have_real || return 0
  rm "$R/a.sh" "$R/b.sh" "$R/dup.sh" "$R/sp ace/c d.sh"
  printf '%b' "$SRCSH" > "$R/a.sh"; printf '%b' "$LIBARR" > "$R/lib.sh"; commit_all
  lcr; expect rc_array 1 "$RC"
  printf '#!/bin/bash\nARR=1\necho "$ARR"\n' > "$R/lib.sh"      # only lib.sh changes
  lcr; expect rc_scalar 0 "$RC"
  expect summary "shellcheck: 2 unique script(s) of 2 clean at severity=warning (cached 0, linted 2; sourcing 1)" "$(sumline)"
  lcr; expect rc_scalar_warm 0 "$RC"; expect warm_cached "shellcheck: 2 unique script(s) of 2 clean at severity=warning (cached 2, linted 0; sourcing 1)" "$(sumline)"
  printf '%b' "$LIBARR" > "$R/lib.sh"
  lcr; expect rc_array_again 1 "$RC"
}
t_real_rc_representative_case_b() {
  # identical content at z.sh and sub/a.sh, sub/.shellcheckrc disables the finding: the verdict
  # of each path is its own, whichever is first and whichever is deleted
  have_real || return 0
  rm "$R/a.sh" "$R/b.sh" "$R/dup.sh" "$R/sp ace/c d.sh"; mkdir -p "$R/sub"
  printf '%b' "$LOOP_DIRTY" > "$R/z.sh"; printf '%b' "$LOOP_DIRTY" > "$R/sub/a.sh"
  printf 'disable=SC2045\n' > "$R/sub/.shellcheckrc"; commit_all
  lcr; expect both_present_rc 1 "$RC"
  grep -q '^In z.sh' "$C/out" || fail "finding not under z.sh"; grep -q '^In sub/a.sh' "$C/out" && fail "sub/a.sh must be clean (its rc disables SC2045)"
  lcr; expect both_present_warm_rc 1 "$RC"
  ( cd "$R" && git rm -q z.sh ); lcr; expect only_sub_rc 0 "$RC"
  ( cd "$R" && git reset -q --hard && git rm -q sub/a.sh ); lcr; expect only_z_rc 1 "$RC"
  ( cd "$R" && git reset -q --hard ); lcr; expect restored_rc 1 "$RC"
}
t_real_untracked_nested_rc_flips() {
  have_real || return 0
  rm "$R/a.sh" "$R/b.sh" "$R/dup.sh" "$R/sp ace/c d.sh"; mkdir -p "$R/sub"
  printf '%b' "$LOOP_DIRTY" > "$R/sub/a.sh"; commit_all
  lcr; expect no_rc 1 "$RC"
  printf 'disable=SC2045\n' > "$R/sub/.shellcheckrc"; lcr; expect untracked_nested_rc_added 0 "$RC"
  lcr; expect warm 0 "$RC"
  rm "$R/sub/.shellcheckrc"; lcr; expect removed 1 "$RC"
  printf 'disable=SC2045\n' > "$C/.shellcheckrc"; lcr; expect ancestor_above_repo_added 0 "$RC"
  rm "$C/.shellcheckrc"; lcr; expect ancestor_removed 1 "$RC"
}

CASES="cold_lints_each_unique_once warm_invokes_shellcheck_zero_times edit_relints_exactly_that_content identical_content_linted_once dirty_file_is_never_cached fixing_a_dirty_file_makes_it_clean_and_cached one_file_per_call_with_x dirty_file_does_not_block_others_being_recorded untracked_sh_is_not_linted shellcheck_version_change_relints_all severity_change_relints_all shellcheckrc_change_relints_all zero_tracked_sh_is_exit_2 shellcheck_missing_is_exit_2 cache_off_lints_all_but_still_stores verify_mode_relints_and_catches_a_lie cache_dir_not_a_directory_is_exit_2 cache_dir_symlink_is_exit_2 output_is_identical_for_one_and_four_jobs paths_with_spaces odd_filenames all_cached_process_count_is_constant sourcing_file_relinted_when_lib_changes source_variants_are_classed_sourcing sourcing_key_includes_directory rc_chain_nearest_wins rc_chain_untracked_nested_and_ancestor forged_entries_are_ignored shellcheck_exit_2_is_tool_error killed_shellcheck_is_tool_error script_hash_is_in_the_key no_tmp_left_in_cache real_shellcheck_basic real_src_repro real_lib_change_flips_verdict real_rc_representative_case_b real_untracked_nested_rc_flips"

one_case() {
  local n=$1 want=""
  newcase "$n"; FAILS=""; INFO=""
  "t_$n"
  [ -z "$INFO" ] || want=" ($INFO)"
  if [ -z "$FAILS" ]; then printf 'ok   %s%s\n' "$n" "$want"; else printf 'FAIL %s:%s\n' "$n" "$FAILS"; fi
}
run_cases() {
  local n ok=0 bad=0 line total=0 t0
  for n in $CASES; do
    if [ -n "${LINT_SELFTEST_ONLY:-}" ]; then case " $LINT_SELFTEST_ONLY " in *" $n "*) ;; *) continue ;; esac; fi
    total=$((total + 1))
    t0=$SECONDS; line=$(one_case "$n" 2>&1)
    [ $((SECONDS - t0)) -lt 3 ] || line="$line [$((SECONDS - t0))s]"
    printf '%s\n' "$line"
    case $line in ok*) ok=$((ok + 1)) ;; *) bad=$((bad + 1)) ;; esac
  done
  printf '%s ok, %s failed\n' "$ok" "$bad"
  [ "$total" -gt 0 ] || { echo "no case ran" >&2; exit 2; }
  [ "$bad" -eq 0 ]
}

# ---- mutations --------------------------------------------------------------------
# id @@ marker=replacement line (';;' separates several) @@ guarding cases
MUTATIONS=$(cat <<'EOF'
dirty-results-cached@@storeall=        dirty=$((dirty + 1)); printf '%s\n' "${KEY[i]}" >> "$T/store"@@dirty_file_is_never_cached
tool-version-dropped@@verkey=  :@@shellcheck_version_change_relints_all
severity-dropped-from-key@@sevkey=  :@@severity_change_relints_all
path-instead-of-content-hash@@contentkey=      printf "content=%s\n", p > f@@edit_relints_exactly_that_content
zero-files-guard-removed@@zeroguard=  :;;zeroguard2=:;;zeroguard3=:@@zero_tracked_sh_is_exit_2
verify-does-not-relint@@verify=  if [ "$hit" = 1 ]; then c=$((c + 1)); continue; fi@@verify_mode_relints_and_catches_a_lie
dedupe-removed@@dedupe=      k = K[i] "|" P[i]@@identical_content_linted_once cold_lints_each_unique_once
cache-never-hit@@keyhit=  :@@warm_invokes_shellcheck_zero_times
x-removed@@noxflag=shellcheck -S "$SEV" -- "$2" > "$T/o.$1" 2>&1@@real_src_repro one_file_per_call_with_x
sources-component-dropped@@srcclass=      flag = 0@@sourcing_file_relinted_when_lib_changes source_variants_are_classed_sourcing real_lib_change_flips_verdict
rc-chain-dropped-from-key@@rcchain=      if false; then@@rc_chain_nearest_wins rc_chain_untracked_nested_and_ancestor real_rc_representative_case_b real_untracked_nested_rc_flips shellcheckrc_change_relints_all
directory-dropped-for-sourcing@@srcdir=      if (flag) printf "sources=%s\n", ss > f@@sourcing_key_includes_directory
entry-trusted-by-existence@@entryexists=  [ -e "$f" ] || [ -L "$f" ] && return 0; return 1@@forged_entries_are_ignored
script-hash-dropped@@selfkey=  :@@script_hash_is_in_the_key
exit-ge2-mapped-to-findings@@rc1=    [1-9]*)@@shellcheck_exit_2_is_tool_error killed_shellcheck_is_tool_error
exit-ge2-mapped-to-clean@@rc0=    0 | [2-9]* | 1[0-9][0-9])@@shellcheck_exit_2_is_tool_error killed_shellcheck_is_tool_error
output-sort-removed@@sortout=    for (k in rep) print rep[k] "\t" k "\t" fl[k] "\t" oth[k];;sortpipe=  }' "$T/meta" "$T/keys" > "$T/groups"@@output_is_identical_for_one_and_four_jobs
EOF
)
mutate_line() { # file id replacement
  local f=$1 id=$2 repl=$3
  REPL=$repl ID=$id awk '{ if (index($0, "# MUT:" ENVIRON["ID"]) && $0 ~ ("# MUT:" ENVIRON["ID"] "$")) print ENVIRON["REPL"]; else print }' "$f" > "$f.m" && mv "$f.m" "$f"
}
mutant_parses() { # does the mutant RUN through to its end on a clean fixture without a shell syntax error?
  # (bash reads a script command by command, so only an execution proves it parses)
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
    d="$T/mut/$id"; mkdir -p "$d"; cp "$subject" "$d/lint-cached.sh"
    rest=$spec
    while [ -n "$rest" ]; do
      case $rest in *';;'*) pair=${rest%%;;*}; rest=${rest#*;;} ;; *) pair=$rest; rest="" ;; esac
      mid=${pair%%=*}; repl=${pair#*=}
      mutate_line "$d/lint-cached.sh" "$mid" "$repl"
    done
    if cmp -s "$subject" "$d/lint-cached.sh"; then printf 'ERROR %-30s mutation did not change the script (marker missing?)\n' "$id"; green=$((green + 1)); continue; fi
    if ! mutant_parses "$d/lint-cached.sh"; then printf 'ERROR %-30s mutant does not parse: %s\n' "$id" "$(grep -E 'syntax error|unexpected' "$C/err" | head -1)"; green=$((green + 1)); continue; fi
    out=$(LINT_CACHE_SUBJECT="$d/lint-cached.sh" LINT_SELFTEST_ONLY="$cases" "$BASH_BIN" "$SELF" 2>&1); base=$?
    if [ "$base" -eq 1 ]; then printf 'RED   %-30s %s\n' "$id" "$(printf '%s\n' "$out" | grep '^FAIL' | head -1 | cut -c1-100)"; red=$((red + 1))
    else printf 'GREEN %-30s the guarding case(s) [%s] still pass: that part is unguarded\n' "$id" "$cases"; green=$((green + 1)); fi
  done <<EOF
$MUTATIONS
EOF
  printf '%s RED, %s not RED\n' "$red" "$green"
  [ "$green" -eq 0 ]
}

if [ "${1:-}" = "--mutations" ]; then
  all=$(grep -v '^$' <<<"$MUTATIONS" | awk -F'@@' '{printf "%s ", $3}')
  [ -n "${LINT_MUT_ONLY:-}" ] || LINT_SELFTEST_ONLY="$all" run_cases >/dev/null || { echo "baseline: the guarding cases fail on the unmutated subject" >&2; exit 2; }
  run_mutations
  exit $?
fi
run_cases
