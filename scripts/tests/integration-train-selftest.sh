#!/usr/bin/env bash
# integration-train-selftest.sh -- hermetic proof of scripts/integration-train.py.
#
# One scratch BARE repo (built by one `git fast-import`), a linked worktree of it
# as "the caller's tree" (made dirty on purpose), a fake verify script. No
# network, no Docker. Every case asserts the summary JSON AND the git state:
# integration branch content, commit count, and the caller's tree untouched.
#
# Set TRAIN_SCRIPT to point at a mutated copy (mutation proofs do exactly that);
# FAILFAST=1 stops at the first FAIL line (a mutation proof needs one RED line, not all).
# ORC_N sets how many generated oracle scenarios run (default 60).
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT=${TRAIN_SCRIPT:-$HERE/../integration-train.py}
REAL_GIT=$(command -v git)
export REAL_GIT
S=$(mktemp -d "${TMPDIR:-/tmp}/itrain-selftest.XXXXXX")
trap 'rm -rf -- "$S"' EXIT
mkdir -p "$S/tmp" "$S/bin" "$S/logs"
export TMPDIR=$S/tmp
export GITLOG=$S/gitlog
BARE=$S/bare.git
WT=$S/wt
PASS=0
FAIL=0
T0=$SECONDS

ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; [ -z "${FAILFAST:-}" ] || exit 1; }
check() { # desc, then a test command
    local d=$1
    shift
    if "$@"; then ok; else bad "$d"; fi
}
lacks() { ! has "$1" "$2"; }
has() { case $1 in *"$2"*) return 0 ;; esac; return 1; }
eq() { [ "$1" = "$2" ]; }
count_of() { # text needle -> number of occurrences
    local rest=${1//"$2"/}
    echo $((( ${#1} - ${#rest} ) / ${#2}))
}

# ---- fixture ---------------------------------------------------------------
fi_file() { printf 'M 100644 inline %s\ndata <<EOF\n%s\nEOF\n' "$1" "$2"; }
fi_commit() { # ref, message, from-mark-or-empty, files as "path=content" ...
    local ref=$1 msg=$2 from=$3
    shift 3
    printf 'commit refs/heads/%s\ncommitter t <t@x> 1700000000 +0000\ndata <<EOF\n%s\nEOF\n' "$ref" "$msg"
    [ -n "$from" ] && printf 'from %s\n' "$from"
    local f
    for f in "$@"; do fi_file "${f%%=*}" "${f#*=}"; done
}
{
    printf 'commit refs/heads/main\nmark :1\ncommitter t <t@x> 1700000000 +0000\ndata <<EOF\nbase\nEOF\n'
    fi_file base.txt base
    fi_file shared.txt "shared v0"
    fi_file conf.txt "$(printf 'l1\nl2\nl3')"
    for n in 1 2 3 4 5 6 7 8; do
        fi_commit "g$n" "add f$n" :1 "f$n.txt=ok $n"
        fi_commit "x$n" "poison f$n" :1 "f$n.txt=POISON"
    done
    fi_commit fa "flag a" :1 "a.flag=a"
    fi_commit fb "flag b" :1 "b.flag=b"
    fi_commit ovA "shared A" :1 "shared.txt=shared A"
    fi_commit ovB "shared B" :1 "shared.txt=shared B"
    fi_commit cf "conf side" :1 "conf.txt=$(printf 'l1\nCF\nl3')"
    fi_commit m3 "m3 one" :1 "mA.txt=A"
    fi_commit m3 "m3 two" "" "mB.txt=B"
    fi_commit m3 "m3 three" "" "mC.txt=C"
    # control characters in a message, a newline and a tab in a path
    fi_commit ctl "$(printf 'ctl subject\001\002 end\nbody line')" :1 '"d\nir/f\tx.txt"=ctl'
    fi_commit ctl2 "$(printf 'two\002 first')" :1 "c2a.txt=1"
    fi_commit ctl2 "$(printf 'two\001 second\nbody')" "" "c2b.txt=2"
    # a merge commit whose OWN diff (evil.txt) is in no side branch
    fi_commit s1 "side one" :1 "mS1.txt=1"
    fi_commit s2 "side two" :1 "mS2.txt=2"
    printf 'commit refs/heads/mg\ncommitter t <t@x> 1700000000 +0000\ndata <<EOF\nmerge both\nEOF\n'
    printf 'from refs/heads/s1\nmerge refs/heads/s2\n'
    fi_file mS2.txt 2
    fi_file evil.txt "evil mg"
    fi_commit ev "evil other" :1 "evil.txt=evil other"
    # a rename, and a change to the old name
    printf 'commit refs/heads/rn\ncommitter t <t@x> 1700000000 +0000\ndata <<EOF\nrename base\nEOF\nfrom :1\nR base.txt base2.txt\n'
    fi_commit ob "touch old name" :1 "base.txt=other"
    # an empty commit, a branch whose two commits cancel out, a change base already has
    printf 'commit refs/heads/em\ncommitter t <t@x> 1700000000 +0000\ndata <<EOF\nempty\nEOF\nfrom :1\n'
    fi_commit nn "add z" :1 "z.txt=z"
    printf 'commit refs/heads/nn\ncommitter t <t@x> 1700000000 +0000\ndata <<EOF\ndel z\nEOF\nD z.txt\n'
    fi_commit pre "already in base" :1 "pre.txt=pre"
    fi_commit main "base moves" "" "conf.txt=$(printf 'l1\nBASE2\nl3')" "pre.txt=pre"
} >"$S/stream"
"$REAL_GIT" init -q --bare -b main "$BARE"
"$REAL_GIT" -C "$BARE" fast-import --quiet <"$S/stream"
"$REAL_GIT" -C "$BARE" worktree add -q -b wtbr "$WT" main
"$REAL_GIT" -C "$WT" config user.name selftest
"$REAL_GIT" -C "$WT" config user.email selftest@localhost
echo dirty >>"$WT/base.txt"
echo scratch >"$WT/scratch.txt"

cat >"$S/verify.sh" <<'EOF'
#!/bin/sh
[ -n "${COUNT:-}" ] && echo x >>"$COUNT"
if grep -rq POISON . ; then echo "FAIL: poison present"; exit 1; fi
if [ -f a.flag ] && [ -f b.flag ]; then echo "FAIL: a.flag and b.flag together"; exit 1; fi
echo ok
EOF
VERIFY="sh $S/verify.sh"

cat >"$S/fakegit" <<'EOF'
#!/bin/bash
# the tool always calls `git -c K=V ... -C DIR sub ...`: find DIR and sub
args=("$@")
dir=$(pwd -P)
i=0
while [ "$i" -lt "${#args[@]}" ]; do
    case ${args[$i]} in
    -c) i=$((i + 2)) ;;
    -C) dir=$(cd "${args[$((i + 1))]}" 2>/dev/null && pwd -P); i=$((i + 2)) ;;
    *) break ;;
    esac
done
sub=${args[$i]:-}
echo "$sub $dir" >>"$GITLOG"
case "$sub" in
push|reset|clean|stash|checkout) echo "forbidden git $sub" >&2; exit 97 ;;
cherry-pick|merge|commit)
    root=$(cd "$TMPDIR" && pwd -P)
    case $dir in
    "$root"/itrain-*) ;;
    *) echo "git $sub outside a temp worktree: $dir" >&2; exit 97 ;;
    esac ;;
esac
exec "$REAL_GIT" "$@"
EOF
chmod +x "$S/fakegit"
mkdir -p "$S/failbin" "$S/oldbin"
cat >"$S/failbin/git" <<'EOF'
#!/bin/bash
args=("$@")
i=0
while [ "$i" -lt "${#args[@]}" ]; do
    case ${args[$i]} in -c | -C) i=$((i + 2)) ;; *) break ;; esac
done
case "${args[$i]:-}" in
merge-tree|cherry-pick|merge) echo "error: unknown option merge-base" >&2
    echo "usage: git ${args[$i]} [options]" >&2; exit 129 ;;
esac
exec "$REAL_GIT" "$@"
EOF
cat >"$S/oldbin/git" <<'EOF'
#!/bin/sh
[ "$1" = "--version" ] && { echo "git version 2.30.1"; exit 0; }
exec "$REAL_GIT" "$@"
EOF
chmod +x "$S/failbin/git" "$S/oldbin/git"
cp "$S/fakegit" "$S/bin/git"

# ---- harness ---------------------------------------------------------------
snap() {
    (
        cd "$WT" || exit 1
        git status --porcelain=v2 --branch
        git branch --list
        git worktree list
        echo "$(<base.txt)$(<scratch.txt)"
    ) 2>&1
}
BEFORE=
begin() { BEFORE=$(snap); }
BR=
trn() { # args to the train; sets OUT RC JSON BR. A hung run is killed after CASE_TIMEOUT s.
    local p=$PATH
    [ -n "${WRAP:-}" ] && p=$S/bin:$PATH
    [ -n "${WRAPDIR:-}" ] && p=$WRAPDIR:$PATH
    local ra=()
    [ -n "${REPOARG:-}" ] && ra=(--repo "$REPOARG")
    # shellcheck disable=SC2086
    (cd "$WT" && exec env ${TENV:-} PATH="$p" python3 -I -B "$SCRIPT" --base "${BASE:-main}" \
        --verify "${V:-$VERIFY}" --log-dir "$S/logs" ${ra[@]+"${ra[@]}"} "$@") >"$S/out.txt" 2>&1 &
    local pid=$!
    (
        sleep "${CASE_TIMEOUT:-25}" &
        sp=$!
        trap 'kill "$sp" 2>/dev/null; exit 0' TERM
        wait "$sp"
        kill -TERM "$pid" 2>/dev/null
    ) &
    local wd=$!
    wait "$pid"
    RC=$?
    kill -TERM "$wd" 2>/dev/null
    wait "$wd" 2>/dev/null
    [ "$RC" = 143 ] && bad "HANG: a train run was killed by the ${CASE_TIMEOUT:-25}s case watchdog"
    OUT=$(<"$S/out.txt")
    JSON=${OUT##*$'\n'}
    BR=
    case $JSON in *'"branch":"'*) BR=${JSON#*\"branch\":\"}; BR=${BR%%\"*} ;; esac
}
finish() { # desc ; drops a kept branch, then proves the caller untouched
    [ -n "$BR" ] && "$REAL_GIT" -C "$BARE" branch -D "$BR" >/dev/null 2>&1
    local after
    after=$(snap)
    check "$1: caller's HEAD, branches, worktrees and working tree untouched" eq "$after" "$BEFORE"
}
subjects() { "$REAL_GIT" -C "$BARE" log --reverse --format=%s "main..$1" | tr '\n' ,; }
ncommits() { "$REAL_GIT" -C "$BARE" rev-list --count "main..$1"; }
inbranch() { "$REAL_GIT" -C "$BARE" cat-file -e "$1:$2" 2>/dev/null; }

# ---- all green -------------------------------------------------------------
begin
trn --keep g1 g2 g3 g4
check "green: exit 0" eq "$RC" 0
check "green: landed in order" has "$JSON" '"landed":["g1","g2","g3","g4"]'
check "green: ONE verify run" has "$JSON" '"runs":1,'
check "green: batch size 4" has "$JSON" '"batch":4'
check "green: 4 commits" eq "$(ncommits "$BR")" 4
check "green: commit order preserved" eq "$(subjects "$BR")" "add f1,add f2,add f3,add f4,"
check "green: content joined" inbranch "$BR" f4.txt
finish "green"

# ---- one poisoned, positions 2 and 3 --------------------------------------
begin
trn --keep g1 x2 g3 g4
check "poison@2: exit 1" eq "$RC" 1
check "poison@2: landed the other 3" has "$JSON" '"landed":["g1","g3","g4"]'
check "poison@2: x2 ejected red" has "$JSON" '"id":"x2","why":"red"'
check "poison@2: exactly 5 runs" has "$JSON" '"runs":5,'
check "poison@2: second half was the skipped one? no, first half red" has "$OUT" "run 3: [g1] green"
check "poison@2: 3 commits, no poison" eq "$(ncommits "$BR")" 3
check "poison@2: poisoned file absent" bash -c "! $REAL_GIT -C $BARE cat-file -e $BR:f2.txt 2>/dev/null"
LOGF=${JSON#*\"log\":\"}
LOGF=${LOGF%%\"*}
check "poison@2: log file names the failure" grep -q "poison present" "$LOGF"
finish "poison@2"

begin
trn --keep g1 g2 x3 g4
check "poison@3: exit 1" eq "$RC" 1
check "poison@3: 5 runs" has "$JSON" '"runs":5,'
check "poison@3: second half known red -> its own run skipped" has "$OUT" "skip: own run of [x3,g4]"
check "poison@3: GREEN member of the second half still lands" has "$JSON" '"landed":["g1","g2","g4"]'
check "poison@3: only x3 ejected" has "$JSON" '"ejected":[{"id":"x3","why":"red"'
check "poison@3: g4 content on branch" inbranch "$BR" f4.txt
finish "poison@3"

begin
trn --no-recover g1 g2 g3 x4
check "poison@4: 4 runs" has "$JSON" '"runs":4,'
check "poison@4: x4 ejected inferred" has "$JSON" '"inferred":true'
check "poison@4: landed 3" has "$JSON" '"landed":["g1","g2","g3"]'
finish "poison@4"

# ---- two poisoned / all poisoned ----------------------------------------
begin
trn --keep --no-recover x1 g2 g3 x4
check "two poisoned: exit 1" eq "$RC" 1
check "two poisoned: landed the 2 green" has "$JSON" '"landed":["g2","g3"]'
check "two poisoned: 7 runs" has "$JSON" '"runs":7,'
check "two poisoned: x1 proven, not inferred" has "$JSON" '{"id":"x1","why":"red","log":"'
check "two poisoned: 2 commits" eq "$(ncommits "$BR")" 2
finish "two poisoned"

begin
trn x1 x2 x3 x4
check "all poisoned: exit 1" eq "$RC" 1
check "all poisoned: nothing landed" has "$JSON" '"landed":[]'
check "all poisoned: no branch" has "$JSON" '"branch":""'
check "all poisoned: 7 runs" has "$JSON" '"runs":7,'
finish "all poisoned"

# ---- interaction ------------------------------------------------------------
begin
trn --keep --no-recover fa g2 fb g4
check "interaction: exit 1" eq "$RC" 1
check "interaction: reported" has "$JSON" '"id":"fb","why":"interaction"'
check "interaction: names the earlier member" has "$JSON" '"with":["fa"]'
check "interaction: later member ejected, earlier keeps its place" has "$JSON" '"landed":["fa","g2"]'
check "interaction: the final set was verified green by a run" has "$OUT" "run 2: [fa,g2] green"
check "interaction: the joined red tree was actually run" has "$OUT" "[fa,g2,fb] red"
check "interaction: 6 runs" has "$JSON" '"runs":6,'
check "interaction: landed branch has a.flag only" bash -c "$REAL_GIT -C $BARE cat-file -e $BR:a.flag && ! $REAL_GIT -C $BARE cat-file -e $BR:b.flag 2>/dev/null"
finish "interaction"

# ---- admission --------------------------------------------------------------
begin
trn --keep g1 ovA g3 ovB
check "overlap: exit 0 (deferral is not ejection)" eq "$RC" 0
check "overlap: deferred with the reason" has "$JSON" '"deferred":[{"id":"ovB","why":"overlaps ovA on shared.txt"}]'
check "overlap: ovB not joined" has "$JSON" '"landed":["g1","ovA","g3"]'
check "overlap: 3 commits" eq "$(ncommits "$BR")" 3
check "overlap: one run" has "$JSON" '"runs":1,'
finish "overlap"

begin
trn g1 cf g3
check "conflict: exit 1" eq "$RC" 1
check "conflict: ejected conflict" has "$JSON" '"id":"cf","why":"conflict"'
check "conflict: rest landed with one run" has "$JSON" '"landed":["g1","g3"],"ejected":[{"id":"cf","why":"conflict","log":"'
check "conflict: no run line mentions it" lacks "$OUT" "run 1: [g1,cf"
check "conflict: one verify run only" has "$JSON" '"runs":1,'
finish "conflict"

begin
trn cf
check "conflict only: exit 3 (nothing verified)" eq "$RC" 3
check "conflict only: zero runs" has "$JSON" '"runs":0,'
finish "conflict only"

begin
trn --keep g1 m3
check "multi-commit: exit 0" eq "$RC" 0
check "multi-commit: ONE commit for the 3-commit branch (2 total)" eq "$(ncommits "$BR")" 2
MSG=$("$REAL_GIT" -C "$BARE" log -1 --format=%B "$BR")
check "multi-commit: subject is the candidate name" eq "${MSG%%$'\n'*}" m3
check "multi-commit: body lists the original subjects" has "$MSG" "- m3 two"
check "multi-commit: all three files present" bash -c "$REAL_GIT -C $BARE cat-file -e $BR:mA.txt && $REAL_GIT -C $BARE cat-file -e $BR:mC.txt"
finish "multi-commit"

# ---- adaptive window --------------------------------------------------------
rm -f "$S/state"
ST=$S/state
begin
trn --state "$ST" g1 g2 g3 g4
STATE=$(cat "$ST")
check "adaptive A: window 4 used, green first run -> next 5" has "$STATE" '"next":5'
trn --state "$ST" g1 g2 g3 g4 g5 g6
check "adaptive B: window 5 admits 5" has "$JSON" '"batch":5'
check "adaptive B: sixth deferred batch full" has "$JSON" '{"id":"g6","why":"batch full"}'
STATE=$(cat "$ST")
check "adaptive B: next 6" has "$STATE" '"next":6'
trn --state "$ST" x1 g2 g3 g4 g5 g6
STATE=$(cat "$ST")
check "adaptive C: red -> halved to 3" has "$STATE" '"next":3'
check "adaptive C: window recorded" has "$STATE" '"window":6'
check "adaptive C: p and run count recorded" has "$STATE" '"last_runs":'
trn --state "$ST" x1 g2 g3
STATE=$(cat "$ST")
check "adaptive D: red -> 1" has "$STATE" '"next":1'
check "adaptive D: p = ejected/attempted" has "$STATE" '"last_p":0.3333'
trn --state "$ST" x1 g2
STATE=$(cat "$ST")
check "adaptive E: window 1 admits only x1" has "$JSON" '"batch":1'
check "adaptive E: red at 1 stays 1 (min)" has "$STATE" '"next":1'
check "adaptive E: p = 1" has "$STATE" '"last_p":1.0'
trn --state "$ST" g1 g2
STATE=$(cat "$ST")
check "adaptive F: green again -> 2" has "$STATE" '"next":2'
finish "adaptive"

# ---- flaky rerun -------------------------------------------------------------
printf '# known flaky\nflakyname_[0-9]+\n' >"$S/flaky.txt"
rm -f "$S/ctr"
begin
V='n=$(cat '"$S"'/ctr 2>/dev/null || echo 0); echo $((n+1)) > '"$S"'/ctr; if [ $n -ge 1 ]; then exit 0; fi; echo FAIL flakyname_7; exit 1' \
    trn --flaky-rerun "$S/flaky.txt" g1
check "flaky: matching red re-run once, then green -> landed" eq "$RC" 0
check "flaky: reported" has "$OUT" "rerun: matched flakyname_[0-9]+"
check "flaky: 2 runs" has "$JSON" '"runs":2,'
finish "flaky once"

V='echo FAIL flakyname_7; exit 1' trn --flaky-rerun "$S/flaky.txt" g1
check "flaky: matching but red twice stays red" eq "$RC" 1
check "flaky: re-run happened exactly once" eq "$(count_of "$OUT" 'rerun: matched')" 1
check "flaky: 2 runs, ejected" has "$JSON" '"runs":2,'

V='echo FAIL other_thing; exit 1' trn --flaky-rerun "$S/flaky.txt" g1
check "flaky: non-matching failure is NOT re-run" has "$JSON" '"runs":1,'
check "flaky: no rerun line" eq "$(count_of "$OUT" 'rerun:')" 0

V='echo FAIL flakyname_7; exit 1' trn g1
check "flaky: without --flaky-rerun a red is a red" has "$JSON" '"runs":1,'

# ---- timeout -----------------------------------------------------------------
begin
T1=$SECONDS
V='sh -c "sleep 29.37 & wait"' trn --verify-timeout 1 g1
T2=$SECONDS
check "timeout: red, reason timeout" has "$JSON" '"id":"g1","why":"timeout"'
check "timeout: took about a second" test $((T2 - T1)) -le 4
check "timeout: no child survived" bash -c "! pgrep -f '[s]leep 29.37' >/dev/null"
finish "timeout"

# ---- cleanup: success, red, SIGTERM ----------------------------------------
begin
trn g1 g2
finish "cleanup after success"
begin
trn x1 g2
finish "cleanup after red"
check "cleanup: no train temp dir left" eq "$(ls "$S/tmp" | wc -l | tr -d ' ')" 0

mkfifo "$S/fifo"
begin
(cd "$WT" && PATH=$PATH exec python3 -I -B "$SCRIPT" --base main --log-dir "$S/logs" \
    --verify "echo go > $S/fifo; sleep 28.41" g1 g2) >"$S/sig.out" 2>&1 &
SPID=$!
exec 3<>"$S/fifo"
read -t 8 -r _ <&3
exec 3>&-
MID=$(snap)
check "SIGTERM: a temp worktree really existed mid-run" bash -c "! [ '$MID' = '$BEFORE' ]"
kill -TERM "$SPID"
wait "$SPID"
SRC=$?
check "SIGTERM: exit 143" eq "$SRC" 143
check "SIGTERM: verify child group killed" bash -c "! pgrep -f '[s]leep 28.41' >/dev/null"
finish "cleanup after SIGTERM"
check "SIGTERM: no train temp dir left" eq "$(ls "$S/tmp" | wc -l | tr -d ' ')" 0

# ---- refusals -----------------------------------------------------------------
trn nosuch-branch
check "unresolvable candidate: exit 2" eq "$RC" 2
BASE=nosuch trn g1
check "unresolvable base: exit 2" eq "$RC" 2
(cd "$WT" && python3 -I -B "$SCRIPT" --base main --verify true >/dev/null 2>&1)
check "no candidates: usage exit 2" eq "$?" 2

# ---- never push/reset/clean/stash/checkout (wrapper on PATH) ----------------
: >"$GITLOG"
begin
WRAP=1 trn --keep g1 m3 g3 g4
check "wrapper: green run works through the fake git" eq "$RC" 0
"$REAL_GIT" -C "$BARE" branch -D "$BR" >/dev/null 2>&1
WRAP=1 trn x1 g2 g3 x4
check "wrapper: red run works through the fake git" eq "$RC" 1
GL=$(cat "$GITLOG")
check "wrapper: git was really intercepted" has "$GL" worktree
check "wrapper: cherry-pick ran in a temp worktree (the wrapper refuses elsewhere)" has "$GL" "cherry-pick "
check "wrapper: squash merge ran in a temp worktree" has "$GL" "merge "
check "wrapper: never push/reset/clean/stash/checkout" bash -c "! grep -Eq '^(push|reset|clean|stash|checkout) ' '$GITLOG'"
finish "wrapper"

# ---- a git failure is a prompt exit 2, never a hang ---------------------------
begin
T1=$SECONDS
WRAPDIR=$S/failbin V='sleep 27.77' trn g1 g2
T2=$SECONDS
check "git failure: exit 2" eq "$RC" 2
check "git failure: one-line error" eq "$(count_of "$OUT" $'\n')" 0
check "git failure: error names the failing git subcommand" has "$OUT" "error: git "
check "git failure: under 3 s" test $((T2 - T1)) -le 3
check "git failure: no verify child left" bash -c "! pgrep -f '[s]leep 27.77' >/dev/null"
check "git failure: no temp dir left" eq "$(ls "$S/tmp" | wc -l | tr -d ' ')" 0
finish "git failure"

begin
WRAPDIR=$S/oldbin trn g1
check "old git: exit 2" eq "$RC" 2
check "old git: names found and required versions" has "$OUT" "git 2.30 found, 2.31 or newer required"
finish "old git"

# ---- B1: every verify run starts on a byte-clean worktree ----------------------
# red unless a file `leftover` exists, and it creates it: any artefact reused between
# runs turns a red tree green.
LEFT='if [ -f leftover ]; then exit 0; fi; touch leftover; echo FAIL flakyname_7; exit 1'
begin
V=$LEFT trn --flaky-rerun "$S/flaky.txt" g1
check "B1 rerun: the rerun does not see the first run's file -> still red, exit 1" eq "$RC" 1
check "B1 rerun: nothing landed" has "$JSON" '"landed":[]'
check "B1 rerun: both runs happened" has "$JSON" '"runs":2,'
finish "B1 rerun"
begin
V=$LEFT trn g1 g2 g3
check "B1 bisection: every step is red on a clean tree, nothing landed" has "$JSON" '"landed":[]'
check "B1 bisection: all three ejected" eq "$(count_of "$JSON" '"why":"red"')" 3
finish "B1 bisection"

# ---- the caller's repo H: hooks, a filter driver, a dirty index -----------------
H=$S/h
HLOG=$S/hooklog
: >"$HLOG"
"$REAL_GIT" init -q -b main "$H"
{
    printf 'commit refs/heads/main\nmark :1\ncommitter t <t@x> 1700000000 +0000\ndata <<EOF\nbase\nEOF\n'
    fi_file f.txt "$(printf 'l1\nl2\nl3')"
    fi_file a.dat dat
    fi_file .gitattributes '*.dat filter=spy'
    fi_commit hg "add g1" :1 "g1.txt=ok"
    fi_commit hx "poison" :1 "f9.txt=POISON"
    fi_commit hcf "conf side" :1 "f.txt=$(printf 'l1\nCF\nl3')"
    fi_commit hms "ms one" :1 "ms1.txt=1"
    fi_commit hms "ms two" "" "ms2.txt=2"
    fi_commit main "base moves" "" "f.txt=$(printf 'l1\nBASE2\nl3')"
} >"$S/hstream"
"$REAL_GIT" -C "$H" fast-import --quiet <"$S/hstream"
"$REAL_GIT" -C "$H" reset -q --hard
"$REAL_GIT" -C "$H" config filter.spy.smudge "echo smudge >>$HLOG; cat"
"$REAL_GIT" -C "$H" config filter.spy.clean "echo clean >>$HLOG; cat"
for hk in post-checkout post-commit pre-commit commit-msg reference-transaction post-merge \
    prepare-commit-msg pre-merge-commit post-rewrite; do
    printf '#!/bin/sh\necho %s >>%s\nexit 0\n' "$hk" "$HLOG" >"$H/.git/hooks/$hk"
    chmod +x "$H/.git/hooks/$hk"
done
# control: the hooks and the filter DO fire when git is run without the tool
"$REAL_GIT" -C "$H" worktree add -q --detach "$S/ctlwt" main
"$REAL_GIT" -C "$H" worktree remove --force "$S/ctlwt"
HLTXT=$(cat "$HLOG")
check "hook control: post-checkout fires without the tool" has "$HLTXT" post-checkout
check "hook control: reference-transaction fires without the tool" has "$HLTXT" reference-transaction
check "hook control: the filter smudge fires without the tool" has "$HLTXT" smudge
echo dirty >>"$H/f.txt"
echo staged >"$H/staged.txt"
"$REAL_GIT" -C "$H" add staged.txt
echo untracked >"$H/untracked.txt"
: >"$HLOG"
hsnap() {
    cksum "$H/.git/index" "$H/f.txt" "$H/staged.txt" "$H/untracked.txt" "$H/.git/HEAD"
    GIT_OPTIONAL_LOCKS=0 "$REAL_GIT" -C "$H" for-each-ref
    GIT_OPTIONAL_LOCKS=0 "$REAL_GIT" -C "$H" status --porcelain=v2 --branch
    "$REAL_GIT" -C "$H" worktree list
}
HBEFORE=$(hsnap)
hdrop() { [ -n "$BR" ] && "$REAL_GIT" -C "$H" branch -D "$BR" >/dev/null 2>&1; : >"$HLOG"; }

# B3: no hook, no filter driver of the caller's repo runs: green, red, conflict, squash
: >"$HLOG"
REPOARG=$H trn --keep hg hx hcf hms
check "B3: exit 1" eq "$RC" 1
check "B3: green pick and squash landed" has "$JSON" '"landed":["hg","hms"]'
check "B3: the conflict path ran" has "$JSON" '"id":"hcf","why":"conflict"'
check "B3: the red path ran, hx ejected red" has "$JSON" '"id":"hx","why":"red"'
check "B3: the hook and filter log is EMPTY" eq "$(wc -c <"$HLOG" | tr -d ' ')" 0
hdrop
check "B3: caller's repo H byte-identical after the run" eq "$(hsnap)" "$HBEFORE"

# B2: GIT_DIR / GIT_WORK_TREE / GIT_INDEX_FILE pointing at the caller's repo are stripped
: >"$HLOG"
REPOARG=$H TENV="GIT_DIR=$H/.git GIT_WORK_TREE=$H GIT_INDEX_FILE=$H/.git/index" \
    V='[ -z "${GIT_DIR:-}${GIT_WORK_TREE:-}${GIT_INDEX_FILE:-}" ]' trn --keep hg
check "B2: runs and lands with the caller's GIT_* set (verify saw none of them)" has "$JSON" '"landed":["hg"]'
check "B2: exit 0" eq "$RC" 0
check "B2: no hook ran" eq "$(wc -c <"$HLOG" | tr -d ' ')" 0
hdrop
check "B2: caller's refs, index, tree and branch main byte-identical" eq "$(hsnap)" "$HBEFORE"
for tv in "GIT_DIR=$H/.git" "GIT_WORK_TREE=$H"; do
    TENV=$tv trn hg
    check "B2: $tv without --repo is refused, exit 2" eq "$RC" 2
    check "B2: $tv refusal says pass --repo" has "$OUT" "pass --repo"
done
check "B2: refusals left H untouched" eq "$(hsnap)" "$HBEFORE"
REPOARG=$S/nonexistent trn g1
check "bad --repo: exit 2" eq "$RC" 2
check "bad --repo: one line, no traceback" eq "$(count_of "$OUT" $'\n')" 0
REPOARG=$S/logs trn g1
check "--repo that is no repository: exit 2" eq "$RC" 2
check "--repo that is no repository: names it" has "$OUT" "not a git repository"
# a repo config that runs code on checkout via a long-running filter is refused
"$REAL_GIT" -C "$H" config filter.lfsish.process "echo process >>$HLOG"
: >"$HLOG"
REPOARG=$H trn hg
check "filter.process in the repo config: refused, exit 2" eq "$RC" 2
check "filter.process: the process filter never ran" eq "$(wc -c <"$HLOG" | tr -d ' ')" 0
"$REAL_GIT" -C "$H" config --unset filter.lfsish.process

# B4: a pre-existing branch of the wanted name survives, the run exits 2
mkdir -p "$S/collidebin"
cat >"$S/collidebin/git" <<'EOF'
#!/bin/bash
cur=
prev=
for a in "$@"; do prev=$cur; cur=$a; done
case " $* " in
*" branch train-"*)
    "$REAL_GIT" -C "$COLLIDE_REPO" update-ref "refs/heads/$prev" "$COLLIDE_SHA"
    echo "$prev" >"$COLLIDE_NAME" ;;
esac
exec "$REAL_GIT" "$@"
EOF
chmod +x "$S/collidebin/git"
export COLLIDE_REPO=$BARE COLLIDE_NAME=$S/collided
COLLIDE_SHA=$("$REAL_GIT" -C "$BARE" rev-parse main)
export COLLIDE_SHA
begin
WRAPDIR=$S/collidebin trn --keep g1 g2
CNAME=$(cat "$S/collided" 2>/dev/null)
check "B4: the wrapper really created the colliding branch" test -n "$CNAME"
check "B4: exit 2 when the branch name exists" eq "$RC" 2
check "B4: the pre-existing branch survives, unmoved" eq "$("$REAL_GIT" -C "$BARE" rev-parse "refs/heads/$CNAME" 2>&1)" "$COLLIDE_SHA"
"$REAL_GIT" -C "$BARE" update-ref -d "refs/heads/$CNAME"
check "B4: no temp dir left" eq "$(ls "$S/tmp" | wc -l | tr -d ' ')" 0
finish "B4"

# ---- W1: verify output goes to a file, never wholly into memory ------------------
cat >"$S/rss.py" <<'EOF'
import resource, subprocess, sys
out = open(sys.argv[1], "w")
rc = subprocess.run([sys.executable, "-I", "-B"] + sys.argv[2:], stdout=out, stderr=subprocess.STDOUT).returncode
kb = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
print(rc, kb // (1024 * 1024) if sys.platform == "darwin" else kb // 1024)
EOF
rss_run() { # verify command -> sets RRC RMB
    local r
    r=$(cd "$WT" && python3 -I -B "$S/rss.py" "$S/rss.out" "$SCRIPT" --base main --verify "$1" \
        --log-dir "$S/logs" g1)
    RRC=${r%% *}
    RMB=${r##* }
}
begin
rss_run 'yes abcdefghijklmnopqrstuvwxyz0123456789 | head -c 52428800; echo; echo LASTLINE-MARK; exit 1'
check "W1 50 MB of output: the tool exits 1 (red)" eq "$RRC" 1
check "W1 50 MB of output: tool RSS under 90 MB (measured ${RMB} MB)" test "$RMB" -lt 90
RJ=$(tail -n 1 "$S/rss.out")
check "W1 50 MB: the summary is small (only the tail)" test "${#RJ}" -lt 4000
RLOG=${RJ#*\"log\":\"}
RLOG=${RLOG%%\"*}
check "W1 50 MB: the log file holds the last line" grep -q LASTLINE-MARK "$RLOG"
check "W1 50 MB: the log file is bounded (20 lines)" test "$(wc -c <"$RLOG" | tr -d ' ')" -lt 4000
rss_run 'head -c 5000000 /dev/zero | tr "\0" x; exit 1'
RJ=$(tail -n 1 "$S/rss.out")
RLOG=${RJ#*\"log\":\"}
RLOG=${RLOG%%\"*}
check "W1 one 5 MB line: the saved tail is bounded (<= 70 KB)" test "$(wc -c <"$RLOG" | tr -d ' ')" -lt 70000
finish "W1"
# a flaky pattern near the START of a long output is still found (streamed over the file)
rm -f "$S/ctr"
V='n=$(cat '"$S"'/ctr 2>/dev/null || echo 0); echo $((n+1)) > '"$S"'/ctr; if [ $n -ge 1 ]; then exit 0; fi; echo FAIL flakyname_7; yes xxxxxxxxxxxxxxxxxxxxxxxxxxxx | head -c 3000000; exit 1' \
    trn --flaky-rerun "$S/flaky.txt" g1
check "W1 flaky: a pattern far above the kept tail still triggers the rerun" has "$JSON" '"runs":2,'
check "W1 flaky: and the rerun landed" eq "$RC" 0

# ---- W2: strict numeric options ------------------------------------------------
for bad_opt in "--verify-timeout 0" "--verify-timeout -1" "--verify-timeout abc" "--verify-timeout nan" \
    "--verify-timeout inf" "--max-batch 0" "--max-batch -2" "--max-batch 65" "--max-batch x"; do
    # shellcheck disable=SC2086
    trn $bad_opt g1
    check "W2: '$bad_opt' is refused with exit 2" eq "$RC" 2
done

# ---- W3: path sets, control characters, merges, renames ----------------------------
begin
trn --keep ctl ctl2 g1
check "W3 control chars: exit 0, no crash" eq "$RC" 0
check "W3 control chars: all landed" has "$JSON" '"landed":["ctl","ctl2","g1"]'
check "W3 control chars: a path with a newline and a tab is on the branch" inbranch "$BR" $'d\nir/f\tx.txt'
check "W3 control chars: the squash commit (ctl2) is one commit: 3 total" eq "$(ncommits "$BR")" 3
finish "W3 control chars"
begin
trn --keep mg ev g1
check "W3 merge: a path changed INSIDE the merge commit defers a clash" has "$JSON" '"deferred":[{"id":"ev","why":"overlaps mg on evil.txt"}]'
check "W3 merge: the merge candidate landed as ONE commit with its content" bash -c "[ '$(ncommits "$BR")' = 2 ] && $REAL_GIT -C $BARE cat-file -e $BR:evil.txt && $REAL_GIT -C $BARE cat-file -e $BR:mS1.txt"
finish "W3 merge"
begin
trn rn ob g1
check "W3 rename: the OLD name is in the path set" has "$JSON" '"deferred":[{"id":"ob","why":"overlaps rn on base.txt"}]'
finish "W3 rename"

# ---- W4: empty and no-net-change candidates -----------------------------------------
for ec in em nn pre; do
    begin
    trn $ec g1
    check "W4 $ec: exit 1, the train does not fail" eq "$RC" 1
    check "W4 $ec: ejected empty, not conflict" has "$JSON" "\"id\":\"$ec\",\"why\":\"empty\""
    check "W4 $ec: no verify run for it, the rest proceeds" has "$JSON" '"landed":["g1"],"ejected":'
    check "W4 $ec: runs_per names only g1" has "$JSON" '"runs_per":{"g1":1}'
    finish "W4 $ec"
done

# ---- W5: duplicates, state files, conflict-only window, unexpected errors --------------
trn g1 g2 g1
check "W5 duplicate name: exit 2" eq "$RC" 2
check "W5 duplicate name: names it" has "$OUT" "candidate given twice: g1"
"$REAL_GIT" -C "$BARE" branch g1alias g1
trn g1 g1alias
check "W5 two names, one commit: exit 2" eq "$RC" 2
check "W5 two names, one commit: names both" has "$OUT" "g1 and g1alias are the same commit"
"$REAL_GIT" -C "$BARE" branch -D g1alias >/dev/null
printf '{"next": Infinity}' >"$S/badstate"
trn --state "$S/badstate" g1
check "W5 state {next: Infinity}: no crash, exit 0" eq "$RC" 0
check "W5 state {next: Infinity}: warned on one line" has "$OUT" "warning: ignoring --state"
check "W5 state {next: Infinity}: rewritten sanely (5)" has "$(cat "$S/badstate")" '"next":5'
printf '{"next":3}' >"$S/qstate"
trn --state "$S/qstate" cf g1
check "W5 conflict-only ejection does NOT halve the window (3 stays 3)" has "$(cat "$S/qstate")" '"next":3,'
trn --state "$S/qstate" g1 g2
check "W5 a clean green first run grows it (3 -> 4)" has "$(cat "$S/qstate")" '"next":4,'
begin
: >"$S/afile"
trn --log-dir "$S/afile/sub" x1 g2
check "W5 unexpected exception: exit 2" eq "$RC" 2
check "W5 unexpected exception: the last line is JSON with an error" has "$JSON" '"error":"unexpected '
check "W5 unexpected exception: one error line on stderr, no traceback" lacks "$OUT" Traceback
check "W5 unexpected exception: temp dir cleaned" eq "$(ls "$S/tmp" | wc -l | tr -d ' ')" 0
finish "W5 unexpected"

# ---- the recovery pass ------------------------------------------------------------------
begin
trn --keep fa g2 fb g4
check "recovery: the green member the skip rule ejected JOINS" has "$JSON" '"landed":["fa","g2","g4"]'
check "recovery: reported" has "$OUT" "recovered: g4"
check "recovery: the interaction ejection stays" has "$JSON" '"id":"fb","why":"interaction"'
check "recovery: no inferred flag left" lacks "$JSON" inferred
check "recovery: costs exactly one more run (6 + 1)" has "$JSON" '"runs":7,'
check "recovery: branch has 3 commits incl. g4's file" bash -c "[ '$(ncommits "$BR")' = 3 ] && $REAL_GIT -C $BARE cat-file -e $BR:f4.txt"
finish "recovery"
begin
trn --keep --no-recover fa g2 fb g4
check "--no-recover: the member stays ejected, inferred" has "$JSON" '"id":"g4","why":"red","log":"'
check "--no-recover: with the inferred flag" has "$JSON" '"inferred":true'
check "--no-recover: 6 runs" has "$JSON" '"runs":6,'
finish "no-recover"
begin
trn x1 g2 g3 x4
check "recovery: a truly red inferred member is PROVEN red, not landed" has "$JSON" '"landed":["g2","g3"]'
check "recovery: proven line" has "$OUT" "proven: x4"
check "recovery: the proven record has no inferred flag" lacks "$JSON" inferred
check "recovery: proven red WITH the landed set names it" has "$JSON" '"red_with":["g2","g3"]'
check "recovery: 7 + 1 runs" has "$JSON" '"runs":8,'
finish "recovery proven"

# ---- the oracle: generated scenarios, a pure-function verify, the invariant checked
# independently of the tool's internals ----------------------------------------------------
cat >"$S/oracle.py" <<'EOF'
import contextlib, importlib.util, io, json, os, random, subprocess, sys, types

script, scratch, nseeds = sys.argv[1], sys.argv[2], int(sys.argv[3])
G = os.environ["REAL_GIT"]
repo = os.path.join(scratch, "orc.git")
results = []


def res(name, problems):
    results.append("PASS %s" % name if not problems else "FAIL %s: %s" % (name, "; ".join(problems)))


def git(*a, inp=None):
    return subprocess.run([G, "-C", repo] + list(a), capture_output=True, text=True, input=inp, check=True).stdout


subprocess.run([G, "init", "-q", "--bare", "-b", "main", repo], check=True)
stream = ["commit refs/heads/main\nmark :1\ncommitter t <t@x> 1700000000 +0000\ndata <<EOF\nbase\nEOF\n"
          "M 100644 inline base.txt\ndata <<EOF\nbase\nEOF\n"]
for i in range(1, 7):
    stream.append("commit refs/heads/c%d\ncommitter t <t@x> 1700000000 +0000\ndata <<EOF\nadd c%d\nEOF\nfrom :1\n"
                  "M 100644 inline c%d.txt\ndata <<EOF\nc%d\nEOF\n" % (i, i, i, i))
subprocess.run([G, "-C", repo, "fast-import", "--quiet"], input="".join(stream), text=True, check=True)

vsh = os.path.join(scratch, "orc-verify.sh")
with open(vsh, "w") as fh:
    fh.write('''#!/bin/sh
echo x >>"$ORC_COUNT"
while IFS= read -r line; do
  [ -z "$line" ] && continue
  hit=1
  for tok in $line; do
    case $tok in
      '*') ;;
      +*) [ -f "${tok#+}" ] || hit=0 ;;
      -*) [ -f "${tok#-}" ] && hit=0 ;;
    esac
  done
  [ $hit = 1 ] && { echo "FAIL rule: $line"; exit 1; }
done <"$ORC_RULES"
echo ok
''')


def is_red(present, rules):  # the TEST's own predicate, a pure function of the set of candidates
    return any(pos <= present and not (neg & present) for pos, neg in rules)


KINDS = ["single", "pair", "triple", "fixer", "red", "green", "mixed", "single", "pair", "fixer"]
count = os.path.join(scratch, "orc-count")
rules_file = os.path.join(scratch, "orc-rules")
for seed in range(nseeds):
    r = random.Random(seed)
    n = r.randint(2, 6)
    ids = ["c%d" % i for i in r.sample(range(1, 7), n)]
    kind = KINDS[seed % len(KINDS)]
    if kind == "triple" and n < 3:
        kind = "pair"
    rules = []
    if kind == "single":
        rules = [({x}, set()) for x in r.sample(ids, r.randint(1, min(2, n)))]
    elif kind == "pair":
        a, b = r.sample(ids, 2)
        rules = [({a, b}, set())]
    elif kind == "triple":
        rules = [(set(r.sample(ids, 3)), set())]
    elif kind == "fixer":
        a, b = r.sample(ids, 2)
        rules = [({a}, {b})]
    elif kind == "red":
        rules = [(set(), set())]
    elif kind == "mixed":
        a, b, c = (r.sample(ids, 3) + ids)[:3] if n >= 3 else (ids[0], ids[1], ids[1])
        rules = [({a}, set()), ({b, c}, set())] if b != c else [({a}, set())]
    with open(rules_file, "w") as fh:
        for pos, neg in rules:
            fh.write("*\n" if not pos and not neg else
                     " ".join(["+" + x + ".txt" for x in sorted(pos)] + ["-" + x + ".txt" for x in sorted(neg)]) + "\n")
    open(count, "w").close()
    env = dict(os.environ, ORC_RULES=rules_file, ORC_COUNT=count)
    p = subprocess.run([sys.executable, "-I", "-B", script, "--base", "main", "--repo", repo,
                        "--verify", "sh " + vsh, "--max-batch", "8", "--keep",
                        "--log-dir", os.path.join(scratch, "orc-logs")] + ids,
                       capture_output=True, text=True, env=env)
    probs = []
    name = "oracle seed %d %s %s" % (seed, kind, ",".join(ids))
    try:
        js = json.loads(p.stdout.strip().split("\n")[-1])
    except ValueError:
        res(name, ["no JSON summary (exit %d): %s" % (p.returncode, p.stderr[-200:])])
        continue
    landed = js["landed"]
    ejected = {e["id"]: e for e in js["ejected"]}
    deferred = [d["id"] for d in js["deferred"]]
    if "error" in js:
        probs.append("tool error " + js["error"])
    if landed != [x for x in ids if x in landed]:
        probs.append("landed not in input order %s" % landed)
    allids = landed + list(ejected) + deferred
    if sorted(allids) != sorted(ids):
        probs.append("not exactly one category each: %s vs %s" % (allids, ids))
    present = set(landed)
    if landed and is_red(present, rules):
        probs.append("landed set %s is RED by the test's predicate" % landed)
    br = js["branch"]
    if landed:
        base = git("rev-parse", "main").strip()
        chain = git("rev-list", "--reverse", "--parents", br, "^" + base).split("\n")
        chain = [c.split() for c in chain if c]
        if len(chain) != len(landed) or any(len(c) != 2 for c in chain):
            probs.append("branch is not one commit per landed candidate")
        else:
            for c, cid in zip(chain, landed):
                names = set(git("diff-tree", "--no-commit-id", "--name-only", "-r", c[0]).split())
                if names != {cid + ".txt"} or git("log", "-1", "--format=%s", c[0]).strip() != "add " + cid:
                    probs.append("commit for %s is not exactly that candidate: %s" % (cid, names))
        tree = set(git("ls-tree", "-r", "--name-only", br).split())
        if tree != {"base.txt"} | {x + ".txt" for x in landed}:
            probs.append("tree is not base + landed: %s" % sorted(tree))
        git("update-ref", "-d", "refs/heads/" + br)
    elif br:
        probs.append("a branch without landed members")
    for cid, e in ejected.items():
        if e["why"] == "red" and not e.get("inferred") and "red_with" not in e and not is_red({cid}, rules):
            probs.append("%s ejected 'red' (proven) but is green alone" % cid)
        if not is_red({cid}, rules) and not is_red(present | {cid}, rules):
            probs.append("%s is green alone AND green with the landed set, yet ejected (%s)" % (cid, e["why"]))
        if e.get("inferred"):
            probs.append("%s still ejected inferred after the recovery pass" % cid)
    executed = sum(1 for _ in open(count))
    if js["runs"] != executed:
        probs.append("runs=%d but the verify command executed %d times" % (js["runs"], executed))
    want_rc = 3 if executed == 0 else (1 if ejected else 0)
    if p.returncode != want_rc:
        probs.append("exit %d, want %d" % (p.returncode, want_rc))
    if kind == "green" and (landed != ids or js["runs"] != 1):
        probs.append("all-green must land everything in one run")
    if kind == "red" and landed:
        probs.append("always-red landed something")
    res(name, probs)

# the state-file reader, in process: every malformed shape is ignored with ONE warning
spec = importlib.util.spec_from_file_location("it", script)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
for content, want, warn in [
    ('{"next": Infinity}', 4, 1), ('{"next": NaN}', 4, 1), ('{"next": -3}', 4, 1), ('{"next": 0}', 4, 1),
    ('{"next": 99999999999999999999}', 4, 1), ('{"next": 65}', 4, 1), ('{"next": "5"}', 4, 1),
    ('{"next": true}', 4, 1), ('{"next": 5.5}', 4, 1), ('{"next": null}', 4, 1), ('[1]', 4, 1),
    ('not json', 4, 1), ('', 4, 1), ('{"next": 7}', 7, 0), ('{"next": 64}', 64, 0), ('{"next": 1}', 1, 0)]:
    sf = os.path.join(scratch, "orc-state")
    with open(sf, "w") as fh:
        fh.write(content)
    ns = types.SimpleNamespace(a=types.SimpleNamespace(state=sf, max_batch=4))
    err = io.StringIO()
    with contextlib.redirect_stderr(err):
        got = mod.Train.read_state(ns)
    lines = [x for x in err.getvalue().split("\n") if x]
    res("state file %r -> %d, %d warning line(s)" % (content, want, warn),
        ([] if got == want else ["got %r" % got]) + ([] if len(lines) == warn else ["warnings %r" % lines]))
print("\n".join(results))
EOF
ORC_N=${ORC_N:-60}
ORC=$(cd "$S" && python3 -I -B "$S/oracle.py" "$SCRIPT" "$S" "$ORC_N" 2>&1)
while IFS= read -r ol; do
    case $ol in
    PASS*) ok ;;
    *) bad "${ol:0:300}" ;;
    esac
done <<<"$ORC"
check "oracle: ran at least $ORC_N scenarios and the state cases" test "$(count_of "$ORC" PASS)" -ge "$((ORC_N + 16))"

# ---- the model: batches of 4 and 8, one failure at each position ----------
M_RUNS=0
M_GREEN="|"
M_OK=1
M_BAD=0
P=0
m_run() {
    M_RUNS=$((M_RUNS + 1))
    if [ "$P" -ge "$1" ] && [ "$P" -le "$2" ]; then M_OK=0; else
        M_OK=1
        M_GREEN="$M_GREEN$1-$2|"
    fi
}
m_bis() { # lo hi mode(u|p|i)
    local lo=$1 hi=$2 mode=$3 h b1 b2
    M_BAD=0
    if [ "$mode" = u ]; then
        m_run "$lo" "$hi"
        [ "$M_OK" = 1 ] && return 0
    fi
    if [ "$lo" = "$hi" ]; then
        M_BAD=1
        return 0
    fi
    h=$((lo + (hi - lo + 2) / 2 - 1))
    m_bis "$lo" "$h" u
    b1=$M_BAD
    if [ "$b1" = 0 ]; then m_bis $((h + 1)) "$hi" i; else m_bis $((h + 1)) "$hi" u; fi
    b2=$M_BAD
    M_BAD=$((b1 | b2))
}
model() { # N P -> runs
    local n=$1
    P=$2
    M_RUNS=0
    M_GREEN="|"
    m_run 1 "$n"
    if [ "$M_OK" = 0 ]; then
        m_bis 1 "$n" p
        local lo=1 hi=$n
        if [ "$P" = 1 ]; then lo=2; elif [ "$P" = "$n" ]; then hi=$((n - 1)); else lo=0; fi
        if [ "$n" -gt 1 ]; then
            if [ "$lo" = 0 ]; then M_RUNS=$((M_RUNS + 1)); else
                case $M_GREEN in *"|$lo-$hi|"*) ;; *) M_RUNS=$((M_RUNS + 1)) ;; esac
            fi
        fi
    fi
    echo "$M_RUNS"
}
echo "batch position measured expected"
for N in 4 8; do
    for pos in 1 2 3 4 5 6 7 8; do
        [ "$pos" -le "$N" ] || continue
        # default: every position of 4, and one first-half and one second-half position of 8;
        # TABLE_FULL=1 sweeps all 8 (slower: each train run costs ~40 git calls)
        if [ "$N" = 8 ] && [ -z "${TABLE_FULL:-}" ]; then
            case $pos in 2 | 5) ;; *) continue ;; esac
        fi
        set --
        i=1
        while [ "$i" -le "$N" ]; do
            if [ "$i" = "$pos" ]; then set -- "$@" "x$i"; else set -- "$@" "g$i"; fi
            i=$((i + 1))
        done
        trn --max-batch "$N" "$@"
        got=${JSON#*\"runs\":}
        got=${got%%,*}
        want=$(model "$N" "$pos")
        echo "$N $pos $got $want"
        check "table N=$N failure@$pos: measured runs == model ($want)" eq "$got" "$want"
        check "table N=$N failure@$pos: exactly that one ejected, rest landed" has "$JSON" "\"ejected\":[{\"id\":\"x$pos\""
    done
done
COUNT=$S/count
export COUNT
trn g1 x2 g3 g4
unset COUNT
check "independent count: verify script really ran as often as reported" eq "$(wc -l <"$S/count" | tr -d ' ')" 5

echo "integration-train selftest: $PASS ok, $FAIL failed, $((SECONDS - T0)) s"
[ "$FAIL" -eq 0 ]
