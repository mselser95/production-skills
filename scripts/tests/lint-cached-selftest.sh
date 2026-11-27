#!/usr/bin/env bash
# lint-cached-selftest.sh -- proves scripts/lint-cached.sh is an honest cache.
#
# Hermetic and sequential: every case builds its own temp git repo and cache dir
# under one temp root, with a FAKE `shellcheck` first on PATH that logs each file
# it is asked to lint and calls a file "dirty" when its content contains the word
# DIRTY (or its path matches $FAKE_DIRTY). So the cases need no real shellcheck and
# run fast; ONE case uses the real shellcheck and is skipped, with the reason
# printed, when it is not installed. One line per case, then "N ok, M failed".
# Exit 0 all ok, 1 any failure, 2 no case ran.
#
# Usage: lint-cached-selftest.sh [--mutations]
#   --mutations  apply ONE mutation at a time to a scratch COPY of the subject (the
#                lines carrying a `# MUT:<id>` marker), run the cases that guard
#                it, and require RED. Prints RED/GREEN per mutation; exit 1 on any
#                GREEN (that part of the cache is unguarded).
# Env:   LINT_CACHE_SUBJECT  script under test (default ../lint-cached.sh)
#        LINT_SELFTEST_ONLY  space-separated case names (used by --mutations)
set -uo pipefail

case ${BASH_SOURCE[0]} in */*) here=$(cd "${BASH_SOURCE[0]%/*}" && pwd) ;; *) here=$(pwd) ;; esac
subject=${LINT_CACHE_SUBJECT:-$here/../lint-cached.sh}
SELF="$here/${BASH_SOURCE[0]##*/}"
[ -r "$subject" ] || { echo "no subject at $subject" >&2; exit 2; }

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset LINT_CACHE LINT_CACHE_DIR LINT_JOBS LINT_BATCH LINT_SEVERITY SHELLCHECK_OPTS FAKE_DIRTY

T=$(mktemp -d "${TMPDIR:-/tmp}/lint-cache-selftest.XXXXXX") || exit 2
cleanup() { case $T in */lint-cache-selftest.*) rm -rf -- "$T" ;; esac; }
trap cleanup EXIT
BASH_BIN=$BASH
ORIG_PATH=$PATH

# ---- fixtures ---------------------------------------------------------------------
newcase() { # name -> C R CACHE FILES_LOG PROC_LOG; a repo with a, b, dup(=a), "sp ace/c d"
  C="$T/$1"; R="$C/repo"; CACHE="$C/cache"; FILES_LOG="$C/files"; PROC_LOG="$C/proc"
  mkdir -p "$R/sp ace" "$C/bin"; : > "$FILES_LOG"; : > "$PROC_LOG"
  export FILES_LOG PROC_LOG VER_FILE="$C/ver"; printf 'version: 1.0\n' > "$C/ver"
  cat > "$C/bin/shellcheck" <<'FAKE'
#!/bin/sh
echo "shellcheck $*" >> "$PROC_LOG"
if [ "$1" = --version ]; then cat "$VER_FILE"; exit 0; fi
echo "$*" >> "$FILES_LOG.argv"
sev=$2; shift 2; rc=0
[ -z "${FAKE_SLEEP:-}" ] || sleep "0.0$(( $$ % 4 ))"
for f in "$@"; do
  echo "$f" >> "$FILES_LOG"
  dirty=0
  while IFS= read -r l || [ -n "$l" ]; do case $l in *DIRTY*) dirty=1 ;; esac; done < "$f"
  [ -z "${FAKE_DIRTY:-}" ] || case $f in *"$FAKE_DIRTY"*) dirty=1 ;; esac
  if [ "$dirty" = 1 ]; then echo "In $f line 1: finding (severity $sev)"; rc=1; fi
done
exit $rc
FAKE
  chmod +x "$C/bin/shellcheck"
  if [ ! -d "$T/tmpl" ]; then
    mkdir -p "$T/tmpl/sp ace"
    printf 'echo a\n' > "$T/tmpl/a.sh"; printf 'echo b\n' > "$T/tmpl/b.sh"; printf 'echo a\n' > "$T/tmpl/dup.sh"
    printf 'echo c\n' > "$T/tmpl/sp ace/c d.sh"; printf 'text\n' > "$T/tmpl/readme.txt"
    ( cd "$T/tmpl" && git init -q . && git add -A && git commit -qm init )
  fi
  rm -rf -- "$R"; cp -R "$T/tmpl" "$R"
  unset FAKE_DIRTY LINT_CACHE LINT_JOBS LINT_BATCH LINT_SEVERITY SHELLCHECK_OPTS
  export LINT_CACHE_DIR="$CACHE" LINT_BATCH=1 LINT_JOBS=2
}
# shellcheck disable=SC2120

lc() { # run the subject inside the repo with the fake first on PATH
  ( cd "$R" && PATH="$C/bin:$ORIG_PATH" "$BASH_BIN" "$subject" "$@" ) > "$C/out" 2> "$C/err"; RC=$?
}
linted() { wc -l < "$FILES_LOG" | tr -d ' '; }
reset() { : > "$FILES_LOG"; : > "$FILES_LOG.argv"; : > "$PROC_LOG"; }
sumline() { grep '^shellcheck:' "$C/out" | head -1; }
commit_all() { ( cd "$R" && git add -A && git commit -qm c ); }
fail() { FAILS="$FAILS $1;"; }
expect() { # label want got
  [ "$2" = "$3" ] || fail "$1: want [$2] got [$3]"
}
entries() { local n=0 f; for f in "$CACHE"/*; do [ ! -e "$f" ] || n=$((n + 1)); done; echo "$n"; }

# ---- cases ------------------------------------------------------------------------
t_cold_lints_each_unique_once() {
  lc; expect rc 0 "$RC"
  expect lints 3 "$(linted)"
  expect summary "shellcheck: 3 unique script(s) of 4 clean at severity=warning (cached 0, linted 3)" "$(sumline)"
  expect entries 3 "$(entries)"
}
t_warm_invokes_shellcheck_zero_times() {
  lc; reset; lc; expect rc 0 "$RC"
  expect lints 0 "$(linted)"
  expect argv_calls 0 "$(wc -l < "$FILES_LOG.argv" | tr -d ' ')"
  expect summary "shellcheck: 3 unique script(s) of 4 clean at severity=warning (cached 3, linted 0)" "$(sumline)"
}
t_edit_relints_exactly_that_content() {
  lc; reset; printf 'echo b2\n' > "$R/b.sh"   # unstaged edit of a tracked file
  lc; expect rc 0 "$RC"
  expect lints 1 "$(linted)"
  expect which b.sh "$(cat "$FILES_LOG")"
  expect summary "shellcheck: 3 unique script(s) of 4 clean at severity=warning (cached 2, linted 1)" "$(sumline)"
}
t_identical_content_linted_once() {
  rm "$R/b.sh" "$R/sp ace/c d.sh"; commit_all   # a.sh and dup.sh remain, byte-identical
  lc; expect rc 0 "$RC"
  expect lints 1 "$(linted)"
  expect summary "shellcheck: 1 unique script(s) of 2 clean at severity=warning (cached 0, linted 1)" "$(sumline)"
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
}
t_fixing_a_dirty_file_makes_it_clean_and_cached() {
  printf 'echo DIRTY\n' > "$R/b.sh"; lc
  printf 'echo fixed\n' > "$R/b.sh"; reset; lc; expect rc 0 "$RC"
  expect lints 1 "$(linted)"
  reset; lc; expect lints_after 0 "$(linted)"
  expect summary "shellcheck: 3 unique script(s) of 4 clean at severity=warning (cached 3, linted 0)" "$(sumline)"
}
t_batch_mates_of_a_dirty_file_are_recorded_clean() {
  printf 'echo DIRTY\n' > "$R/b.sh"; export LINT_BATCH=8 LINT_JOBS=1
  lc; expect rc 1 "$RC"
  expect entries 2 "$(entries)"
  reset; lc; expect relint b.sh "$(cat "$FILES_LOG")"
}
t_untracked_sh_is_not_linted() {
  lc; printf 'echo DIRTY\n' > "$R/scratch.sh"; reset; lc; expect rc 0 "$RC"
  expect lints 0 "$(linted)"
  expect summary "shellcheck: 3 unique script(s) of 4 clean at severity=warning (cached 3, linted 0)" "$(sumline)"
}
t_shellcheck_version_change_relints_all() {
  lc; printf 'version: 2.0\n' > "$VER_FILE"; reset; lc; expect rc 0 "$RC"
  expect lints 3 "$(linted)"
  expect summary "shellcheck: 3 unique script(s) of 4 clean at severity=warning (cached 0, linted 3)" "$(sumline)"
}
t_severity_change_relints_all() {
  lc; reset; LINT_SEVERITY=style lc; expect rc 0 "$RC"
  expect lints 3 "$(linted)"
  grep -q -- '-S style' "$FILES_LOG.argv" || fail "severity not passed to shellcheck"
  expect summary "shellcheck: 3 unique script(s) of 4 clean at severity=style (cached 0, linted 3)" "$(sumline)"
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
  expect summary "shellcheck: 3 unique script(s) of 4 clean at severity=warning (cached 0, linted 3)" "$(sumline)"
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
t_corrupt_cache_dir_warns_and_lints_all() {
  : > "$C/notadir"; export LINT_CACHE_DIR="$C/notadir"
  lc; expect rc 0 "$RC"; expect lints 3 "$(linted)"
  expect warnings 1 "$(grep -c WARNING "$C/err")"
  printf 'echo DIRTY\n' > "$R/b.sh"; reset; lc; expect rc_findings 1 "$RC"
  expect lints_again 3 "$(linted)"
}
t_output_is_identical_for_one_and_four_jobs() {
  local i; for i in 1 2 3 4 5 6 7 8 9 10 11 12; do printf 'echo %s %s\n' "$i" "$([ $((i % 3)) = 0 ] && echo DIRTY)" > "$R/f$i.sh"; done
  commit_all; export LINT_BATCH=2 FAKE_SLEEP=1
  LINT_CACHE=off LINT_JOBS=1 lc; cp "$C/out" "$C/out1"; expect rc1 1 "$RC"
  LINT_CACHE=off LINT_JOBS=4 lc; cmp -s "$C/out1" "$C/out" || fail "stdout differs between LINT_JOBS=1 and 4"
  [ "$(grep -c '^In ' "$C/out")" = 4 ] || fail "expected 4 findings, got $(grep -c '^In ' "$C/out")"
  LINT_CACHE=off LINT_JOBS=3 lc; cmp -s "$C/out1" "$C/out" || fail "stdout differs for LINT_JOBS=3"
}
t_paths_with_spaces() {
  lc; grep -qx 'sp ace/c d.sh' "$FILES_LOG" || fail "spaced path not linted: $(cat "$FILES_LOG")"
  reset; lc; expect warm 0 "$(linted)"
  printf 'echo DIRTY\n' > "$R/sp ace/c d.sh"; lc; expect rc 1 "$RC"
  grep -q 'In sp ace/c d.sh line 1' "$C/out" || fail "spaced finding not printed"
}
mkproc() { # dir count: a repo of <count> distinct scripts, wrappers counting every external process
  local i
  for i in $(seq 1 "$2"); do printf 'echo %s\n' "$i" > "$R/g$i.sh"; done
  commit_all
  [ -d "$T/wrap" ] || { # built once: the wrappers read $PROC_LOG at run time
    mkdir -p "$T/wrap"; local t real
    for t in git xargs shasum sha256sum awk sort cat ls tr cut mkdir mv grep head rm mktemp cp date sed uname dirname getconf sysctl; do
      real=$(PATH=$ORIG_PATH command -v "$t") || continue
      printf '#!/bin/sh\necho %s >> "$PROC_LOG"\nexec %s "$@"\n' "$t" "$real" > "$T/wrap/$t"; chmod +x "$T/wrap/$t"
    done
  }
}
proc_count() { # warm run under the wrappers -> number of external processes
  LINT_BATCH=200 lc; reset
  ( cd "$R" && PATH="$T/wrap:$C/bin:$ORIG_PATH" "$BASH_BIN" "$subject" ) > "$C/out" 2> "$C/err"; RC=$?
  expect rc 0 "$RC"; expect lints 0 "$(linted)"
  wc -l < "$PROC_LOG" | tr -d ' '
}
t_all_cached_process_count_is_constant() {
  local n20 n400 root=$C
  mkproc "$C" 20; n20=$(proc_count)
  newcase proc400; mkproc "$C" 400; n400=$(proc_count)
  expect same_count "$n20" "$n400"
  [ "$n20" -gt 0 ] && [ "$n20" -le 30 ] || fail "process count $n20 outside 1..30"
  INFO="$n20 processes at 20 and at 400 files"; : "$root"
}
t_source_directive_is_not_cached_when_x_is_on() {
  printf '# shellcheck source=foo.sh\n. ./foo.sh\n' > "$R/s.sh"; printf 'echo foo\n' > "$R/foo.sh"; commit_all
  SHELLCHECK_OPTS=-x lc; reset; SHELLCHECK_OPTS=-x lc; expect rc 0 "$RC"
  expect relint_only_s s.sh "$(cat "$FILES_LOG")"
  reset; lc; expect no_x_cache_miss_first 5 "$(linted)" # different key (SHELLCHECK_OPTS differs): everything re-linted
  reset; lc; expect no_x_warm 0 "$(linted)"
}
t_real_shellcheck() {
  if ! command -v shellcheck >/dev/null; then INFO="SKIPPED: real shellcheck is not installed"; return; fi
  printf '#!/bin/sh\necho ok\n' > "$R/a.sh"; printf '#!/bin/sh\nfor f in $(ls); do echo "$f"; done\n' > "$R/b.sh"
  rm "$R/dup.sh" "$R/sp ace/c d.sh"; commit_all
  ( cd "$R" && PATH="$ORIG_PATH" "$BASH_BIN" "$subject" ) > "$C/out" 2> "$C/err"; RC=$?
  expect rc 1 "$RC"; grep -q SC2045 "$C/out" || fail "real finding SC2045 not printed"
  expect entries 1 "$(entries)"
  printf '#!/bin/sh\necho fine\n' > "$R/b.sh"
  ( cd "$R" && PATH="$ORIG_PATH" "$BASH_BIN" "$subject" ) > "$C/out" 2> "$C/err"; RC=$?
  expect rc_fixed 0 "$RC"; expect summary "shellcheck: 2 unique script(s) of 2 clean at severity=warning (cached 1, linted 1)" "$(sumline)"
}

CASES="cold_lints_each_unique_once warm_invokes_shellcheck_zero_times edit_relints_exactly_that_content identical_content_linted_once dirty_file_is_never_cached fixing_a_dirty_file_makes_it_clean_and_cached batch_mates_of_a_dirty_file_are_recorded_clean untracked_sh_is_not_linted shellcheck_version_change_relints_all severity_change_relints_all shellcheckrc_change_relints_all zero_tracked_sh_is_exit_2 shellcheck_missing_is_exit_2 cache_off_lints_all_but_still_stores verify_mode_relints_and_catches_a_lie corrupt_cache_dir_warns_and_lints_all output_is_identical_for_one_and_four_jobs paths_with_spaces all_cached_process_count_is_constant source_directive_is_not_cached_when_x_is_on real_shellcheck"

one_case() {
  local n=$1 want=""
  newcase "$n"; FAILS=""; INFO=""
  "t_$n"
  [ -z "$INFO" ] || want=" ($INFO)"
  if [ -z "$FAILS" ]; then printf 'ok   %s%s\n' "$n" "$want"; else printf 'FAIL %s:%s\n' "$n" "$FAILS"; fi
}
run_cases() {
  local n ok=0 bad=0 line total=0
  for n in $CASES; do
    if [ -n "${LINT_SELFTEST_ONLY:-}" ]; then case " $LINT_SELFTEST_ONLY " in *" $n "*) ;; *) continue ;; esac; fi
    total=$((total + 1))
    line=$(one_case "$n" 2>&1)
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
dirty-results-cached@@storeall=    if ($3 == 0) print "S\t" $2@@dirty_file_is_never_cached
tool-version-dropped@@verkey=  :@@shellcheck_version_change_relints_all
severity-dropped-from-key@@sevkey=  :@@severity_change_relints_all
path-instead-of-content-hash@@keyhit=      hit = ((prefix "-" rep[g]) in have) && !(rep[g] in nc) ? 1 : 0;;keymap=      print rep[g] "\t" rep[g] "\t" hit > map@@edit_relints_exactly_that_content
zero-files-guard-removed@@zeroguard=  :;;zeroguard2=:;;zeroguard3=:@@zero_tracked_sh_is_exit_2
verify-does-not-relint@@verify=      if (hit) c++@@verify_mode_relints_and_catches_a_lie
dedupe-removed@@dedupe=    g = p@@identical_content_linted_once cold_lints_each_unique_once
EOF
)
mutate_line() { # file id replacement
  local f=$1 id=$2 repl=$3
  REPL=$repl ID=$id awk '{ if (index($0, "# MUT:" ENVIRON["ID"]) && $0 ~ ("# MUT:" ENVIRON["ID"] "$")) print ENVIRON["REPL"]; else print }' "$f" > "$f.m" && mv "$f.m" "$f"
}
run_mutations() {
  local line id spec cases rest pair mid repl d out red=0 green=0 base
  mkdir -p "$T/mut"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    id=${line%%@@*}; line=${line#*@@}; spec=${line%%@@*}; cases=${line#*@@}
    d="$T/mut/$id"; mkdir -p "$d"; cp "$subject" "$d/lint-cached.sh"
    rest=$spec
    while [ -n "$rest" ]; do
      case $rest in *';;'*) pair=${rest%%;;*}; rest=${rest#*;;} ;; *) pair=$rest; rest="" ;; esac
      mid=${pair%%=*}; repl=${pair#*=}
      mutate_line "$d/lint-cached.sh" "$mid" "$repl"
    done
    if cmp -s "$subject" "$d/lint-cached.sh"; then printf 'ERROR %-30s mutation did not change the script (marker missing?)\n' "$id"; green=$((green + 1)); continue; fi
    if ! bash -n "$d/lint-cached.sh" 2> "$d/syntax"; then printf 'ERROR %-30s mutant does not parse: %s\n' "$id" "$(head -1 "$d/syntax")"; green=$((green + 1)); continue; fi
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
  LINT_SELFTEST_ONLY="$all" run_cases >/dev/null || { echo "baseline: the guarding cases fail on the unmutated subject" >&2; exit 2; }
  run_mutations
  exit $?
fi
run_cases
