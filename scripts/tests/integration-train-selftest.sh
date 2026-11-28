#!/usr/bin/env bash
# integration-train-selftest.sh -- hermetic proof of scripts/integration-train.py.
#
# Scratch repositories only (built by `git fast-import`), a fake verify script, a fake git
# on PATH that records and refuses. No network, no Docker. Every case asserts the summary
# JSON AND the git state: the landed branch, and the caller's repository untouched.
#
# The property under test is TWO properties: (1) a tree is reported landed only if that
# exact tree was verified green in a clean worktree; (2) the tool never alters the caller's
# repository except to create the one landed branch, and no program configured in the
# caller's repository runs. (2) is proven with planted programs: scripts that append their
# name to a log OUTSIDE every repository; the log must stay empty.
#
# Knobs:
#   TRAIN_SCRIPT=path   a mutated copy of the tool (mutation proofs do exactly that)
#   FAILFAST=1          stop at the first FAIL line (a mutation proof needs one RED line)
#   SHOWOUT=1           after each FAIL line print the last train run's output (debugging)
#   SECTIONS=a,b        run only these sections (base h oracle table allcfg callers sigmid sweep
#                       iso rm state unrel fs newc); unset = all. Mutation proofs use it.
#   ORC_N=n             generated oracle scenarios (default 8, candidates <= 4)
#   TRAIN_ORACLE_FULL=1 the full sweep: 60 oracle scenarios of up to 6 candidates, the whole
#                       model table, 20 random signals, a 40k-file signal case. CI's NIGHTLY
#                       job should set it (the default run must stay under the repo's budget).
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT=${TRAIN_SCRIPT:-$HERE/../integration-train.py}
REAL_GIT=$(command -v git)
export REAL_GIT
S=$(mktemp -d "${TMPDIR:-/tmp}/itrain-selftest.XXXXXX")
trap 'rm -rf -- "$S"' EXIT
mkdir -p "$S/tmp" "$S/bin" "$S/logs" "$S/home"
export TMPDIR=$S/tmp
export HOME=$S/home
export PLOG=$S/plog
export GITLOG=$S/gitlog
BARE=$S/bare.git
WT=$S/wt
PASS=0
FAIL=0
SKIP=0
T0=$SECONDS
sec() { [ -z "${SECTIONS:-}" ] && return 0; case ",$SECTIONS," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }
skip() { SKIP=$((SKIP + 1)); echo "skipped: $1"; }

ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; [ -z "${SHOWOUT:-}" ] || echo "   last train output: ${OUT:-}" | cut -c1-600; [ -z "${FAILFAST:-}" ] || exit 1; }
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
# the tool always calls `git -c K=V ... (--git-dir=DIR | -C DIR) sub ...`: find DIR and sub
args=("$@")
dir=$(pwd -P)
i=0
while [ "$i" -lt "${#args[@]}" ]; do
    case ${args[$i]} in
    -c) i=$((i + 2)) ;;
    -C) dir=$(cd "${args[$((i + 1))]}" 2>/dev/null && pwd -P); i=$((i + 2)) ;;
    --git-dir=*) dir=${args[$i]#--git-dir=}; i=$((i + 1)) ;;
    *) break ;;
    esac
done
sub=${args[$i]:-}
echo "$sub $dir" >>"$GITLOG"
case "$sub" in
rev-parse|merge-base|rev-list|status|worktree|cherry-pick|ls-tree|diff|log|config)
    # nothing but /dev/null may be on a git call's stdin: a line the harness left there must stay unread
    if IFS= read -r -t 1 _l; then echo "STDIN-READABLE $sub" >>"$GITLOG"; fi ;;
esac
case "$sub" in
push|reset|clean|stash|checkout|fetch|clone) echo "forbidden git $sub" >&2; exit 97 ;;
cherry-pick|merge|commit)
    root=$(cd "$TMPDIR" && pwd -P)
    case $dir in
    "$root"/itrain-*/w*/tree) ;;
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
    case ${args[$i]} in -c | -C) i=$((i + 2)) ;; --git-dir=*) i=$((i + 1)) ;; *) break ;; esac
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
# Each case that asserts "no itrain-* left" must see only what ITS run left: a real leftover is
# moved out of TMPDIR before the next run, so it fails one case, not every later one.
quarantine() {
    local d
    [ -n "${KEEP_LEFT:-}" ] && return 0
    for d in "$S"/tmp/itrain-*; do
        [ -e "$d" ] || continue
        mkdir -p "$S/leftovers"
        mv -- "$d" "$S/leftovers/$RANDOM-${d##*/}"
    done
}
BEFORE=
begin() { BEFORE=$(snap); }
BR=
trn() { # args to the train; sets OUT RC JSON BR. A hung run is killed after CASE_TIMEOUT s.
    local p=$PATH
    quarantine
    [ -n "${WRAP:-}" ] && p=$S/bin:$PATH
    [ -n "${WRAPDIR:-}" ] && p=$WRAPDIR:$PATH
    local ra=()
    [ -n "${REPOARG:-}" ] && ra=(--repo "$REPOARG")
    # shellcheck disable=SC2086
    (cd "$WT" && exec env ${TENV:-} PATH="$p" python3 -I -B "$SCRIPT" --base "${BASE:-main}" \
        --verify "${V:-$VERIFY}" --log-dir "$S/logs" ${ra[@]+"${ra[@]}"} "$@") <"${TSTDIN:-/dev/null}" >"$S/out.txt" 2>&1 &
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
    [ "$RC" = 143 ] && [ -z "${SIGOK:-}" ] && bad "HANG: a train run was killed by the ${CASE_TIMEOUT:-25}s case watchdog"
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

if sec base; then
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
check "SIGTERM: a temp worktree really existed mid-run (in the private repo)" bash -c "ls -d '$S'/tmp/itrain-*/w*/tree >/dev/null 2>&1"
check "SIGTERM: mid-run the CALLER shows no worktree, ref or file change" eq "$MID" "$BEFORE"
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

fi # base (first half)
if sec h; then
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
# a long-running filter and a merge driver in the repo config: no longer refused (the caller's
# config is never loaded), and never run
"$REAL_GIT" -C "$H" config filter.lfsish.process "echo process >>$HLOG"
"$REAL_GIT" -C "$H" config merge.mdrv.driver "echo mdrv >>$HLOG"
: >"$HLOG"
REPOARG=$H trn hg
check "filter.process + merge driver in the repo config: not refused, lands (exit 0)" eq "$RC" 0
check "filter.process + merge driver: neither ever ran" eq "$(wc -c <"$HLOG" | tr -d ' ')" 0
"$REAL_GIT" -C "$H" config --unset filter.lfsish.process
"$REAL_GIT" -C "$H" config --unset merge.mdrv.driver

# B4: a pre-existing branch of the wanted name survives; the verified result is KEPT, not lost
mkdir -p "$S/collidebin"
cat >"$S/collidebin/git" <<'XEOF'
#!/bin/bash
# creates the branch the tool is about to create (just before its create-only update-ref)
case " $* " in
*" update-ref refs/heads/train-"*)
    for a in "$@"; do case $a in refs/heads/train-*) nm=${a#refs/heads/} ;; esac; done
    "$REAL_GIT" -C "$COLLIDE_REPO" update-ref "refs/heads/$nm" "$COLLIDE_SHA"
    echo "$nm" >"$COLLIDE_NAME" ;;
esac
exec "$REAL_GIT" "$@"
XEOF
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
check "B4: JSON says verified-but-not-delivered" has "$JSON" '"delivery_error":"git update-ref failed'
KPRIV=${JSON#*\"private_root\":\"}
KPRIV=${KPRIV%%\"*}
KSHA=${JSON#*\"commit\":\"}
KSHA=${KSHA%%\"*}
check "B4: the private root is named, kept, and holds the verified commit" "$REAL_GIT" --git-dir="$KPRIV/repo.git" cat-file -e "$KSHA^{tree}"
check "B4: the stderr line names the kept repository" has "$OUT" "private repository $KPRIV/repo.git"
check "B4: only the private repository is kept (one itrain dir, no worktrees)" eq "$(ls "$KPRIV" | tr '\n' ' ')" "repo.git "
check "B4: no ref but the colliding one reached the caller" eq "$("$REAL_GIT" -C "$BARE" for-each-ref --format='%(refname)' 'refs/heads/train-*')" "refs/heads/$CNAME"
"$REAL_GIT" -C "$BARE" update-ref -d "refs/heads/$CNAME"
mv "$KPRIV" "$S/kept-b4"
check "B4: nothing else left in TMPDIR" eq "$(ls "$S/tmp" | wc -l | tr -d ' ')" 0
BR=
finish "B4"

fi # h
if sec base; then
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
# item 0: x1 (red ALONE) is also retried once against the final landed set [g2,g3]: red -> a ninth run
check "recovery: 7 + 1 + 1 (the red-alone member's one retry) runs" has "$JSON" '"runs":9,'
check "recovery: the red-alone member stays ejected as red" has "$JSON" '"id":"x1","why":"red"'
check "recovery: x1 record carries red_with" has "$JSON" '"red_with":["g2","g3"]'
check "recovery: x1 record carries verified_red (the set the retry ran)" has "$JSON" '"verified_red":["x1","g2","g3"]'
check "recovery: x1 record carries verified_red_alone" has "$JSON" '"verified_red_alone":true'
finish "recovery proven"

fi # base (second half)
if sec oracle; then
# ---- the oracle: generated scenarios, a pure-function verify, the invariant checked
# independently of the tool's internals ----------------------------------------------------
cat >"$S/oracle.py" <<'EOF'
import contextlib, importlib.util, io, json, os, random, subprocess, sys, types

script, scratch, nseeds, nmax = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
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
ls c[0-9]*.txt 2>/dev/null | tr '\n' ' ' | sed 's/[.]txt//g' >>"$ORC_COUNT"; echo >>"$ORC_COUNT"
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


KINDS = ["single", "pair", "triple", "fixer", "red", "green", "mixed", "fixer-pair", "fixer-poison", "fixer"]
count = os.path.join(scratch, "orc-count")
rules_file = os.path.join(scratch, "orc-rules")


def scenario(name, kind, ids, rules, recover=True, expect=None, judge=None):
    """judge: the rules the TEST's predicate uses when they differ from the verify's (the canary);
    then the problems are returned instead of recorded."""
    vrules, rules = rules, (judge if judge is not None else rules)
    with open(rules_file, "w") as fh:
        rules_w, rules = rules, vrules
        for pos, neg in rules:
            fh.write("*\n" if not pos and not neg else
                     " ".join(["+" + x + ".txt" for x in sorted(pos)] + ["-" + x + ".txt" for x in sorted(neg)]) + "\n")
    rules = rules_w
    open(count, "w").close()
    env = dict(os.environ, ORC_RULES=rules_file, ORC_COUNT=count)
    p = subprocess.run([sys.executable, "-I", "-B", script, "--base", "main", "--repo", repo,
                        "--verify", "sh " + vsh, "--max-batch", "8", "--keep",
                        "--log-dir", os.path.join(scratch, "orc-logs")] + ([] if recover else ["--no-recover"]) + ids,
                       capture_output=True, text=True, env=env)
    probs = []
    name = "oracle %s %s %s%s" % (name, kind, ",".join(ids), "" if recover else " --no-recover")
    try:
        js = json.loads(p.stdout.strip().split("\n")[-1])
    except ValueError:
        res(name, ["no JSON summary (exit %d): %s" % (p.returncode, p.stderr[-200:])])
        return None
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
    if landed and is_red(present, rules):  # (i)
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
    for cid, e in ejected.items():  # (ii) every label literally true, by the TEST's predicate
        S = list(e.get("red_with", e.get("with", [])))
        if e["why"] == "red" and not e.get("inferred") and "red_with" not in e and not is_red({cid}, rules):
            probs.append("%s ejected 'red' (alone) but is green alone" % cid)
        if "red_with" in e and not is_red(set(S) | {cid}, rules):
            probs.append("%s carries red_with %s but that set is GREEN" % (cid, S))
        if e["why"] == "interaction":
            if is_red({cid}, rules):
                probs.append("%s is 'interaction' but red alone" % cid)
            if not is_red(set(e["with"]) | {cid}, rules):
                probs.append("%s interaction with %s but that set is GREEN" % (cid, e["with"]))
            if not e.get("verified_green_alone"):
                probs.append("%s interaction without verified_green_alone" % cid)
        if e.get("verified_green_alone") and is_red({cid}, rules):
            probs.append("%s verified_green_alone but red alone" % cid)
        if e.get("verified_red_alone") and not is_red({cid}, rules):
            probs.append("%s verified_red_alone but green alone" % cid)
        for vs in ([e["verified_red"]] if "verified_red" in e else []):
            if not is_red(set(vs), rules):
                probs.append("%s verified_red %s is GREEN" % (cid, vs))
        if e.get("inferred") and cid not in e.get("verified_red", [cid]):
            probs.append("%s inferred record names a set without it" % cid)
        if recover:  # (iii): after recovery nothing recoverable stays out, red-alone members included
            if e.get("inferred"):
                probs.append("%s still ejected inferred after the recovery pass" % cid)
            if not is_red(present | {cid}, rules):
                probs.append("%s is GREEN together with the FINAL landed set %s, yet ejected (%s)"
                             % (cid, landed, e["why"]))
            if e["why"] not in ("conflict", "uncheckoutable", "empty", "unrelated", "unrepresentable-on-this-filesystem"):
                # the stated guarantee, exactly: the tool's own record says RED with a set equal to the
                # FINAL landed set + this member (the oracle's check above says it really is red)
                if set(e.get("verified_red", [])) != present | {cid}:
                    probs.append("%s: verified_red %s is not the final landed set %s plus itself"
                                 % (cid, e.get("verified_red"), landed))
            if "red_with" in e and not set(e["red_with"]) <= present:
                probs.append("%s red_with %s names a candidate that did not land %s" % (cid, e["red_with"], landed))
    runlog = [frozenset(l.split()) for l in open(count).read().split("\n")[:-1]]
    executed = len(runlog)
    for cid, e in ejected.items():  # (v) every set a label rests on was really RUN (the test's own log)
        if e.get("verified_green_alone") and frozenset([cid]) not in runlog:
            probs.append("%s verified_green_alone but [%s] was never run" % (cid, cid))
        if e["why"] == "red" and not e.get("inferred") and "red_with" not in e and frozenset([cid]) not in runlog:
            probs.append("%s 'red' (alone) but [%s] was never run" % (cid, cid))
        if "verified_red" in e and frozenset(e["verified_red"]) not in runlog and e["why"] != "conflict":
            probs.append("%s verified_red %s was never run" % (cid, e["verified_red"]))
    if js["runs"] != executed:  # (iv)
        probs.append("runs=%d but the verify command executed %d times" % (js["runs"], executed))
    want_rc = 3 if executed == 0 else (1 if ejected else 0)
    if p.returncode != want_rc:
        probs.append("exit %d, want %d" % (p.returncode, want_rc))
    if kind == "green" and (landed != ids or js["runs"] != 1):
        probs.append("all-green must land everything in one run")
    if kind == "red" and landed:
        probs.append("always-red landed something")
    if expect:
        probs += expect(js, landed, ejected)
    if judge is not None:
        return probs
    res(name, probs)
    return js


def want(landed_want, **why):
    """expect=: exact landed list and, per id, the reason it must be ejected for."""
    def f(js, landed, ejected):
        out = []
        if landed != landed_want:
            out.append("landed %s, wanted %s" % (landed, landed_want))
        for k, v in why.items():
            if k not in ejected or ejected[k]["why"] != v:
                out.append("%s: %s, wanted %s" % (k, ejected.get(k, {}).get("why"), v))
        return out
    return f


def f_formula6(js, landed, ejected):
    out = want(["c1", "c2", "c3"], c4="interaction", c5="red", c6="red")(js, landed, ejected)
    if "c4" in ejected and "c3" not in ejected["c4"].get("with", []):
        out.append("c4 interaction with %s, which lacks c3" % ejected["c4"].get("with"))
    return out


def f_n4(js, landed, ejected):  # a reported partner must be green as a SET (never one red alone)
    out = []
    for cid, e in ejected.items():
        S = e.get("with", [])
        if S and is_red(set(S), N4):
            out.append("%s reported with %s, a set that is itself red" % (cid, S))
    return out


def f_n4_norecover(js, landed, ejected):  # without recovery the search itself must run the member ALONE
    out = want(["c2", "c3"], c1="red", c4="interaction")(js, landed, ejected)
    if not ejected.get("c4", {}).get("verified_green_alone"):
        out.append("c4 interaction without the member's own green run")
    return out


N4 = [({"c1"}, {"c3"}), ({"c2", "c4"}, set())]
C6 = ["c1", "c2", "c3", "c4", "c5", "c6"]
FIXED = [
    ("fixed-recovery", "fixed-recovery", ["c1", "c2", "c3", "c4"], [({"c1", "c3"}, set())], None),
    ("fixer-late", "fixer", ["c1", "c2", "c3", "c4"], [({"c1"}, {"c4"}), ({"c2"}, set())], want(["c1", "c3", "c4"], c2="red")),
    ("fixer-pair", "fixer-pair", ["c1", "c2", "c3", "c4", "c5"], [({"c1"}, {"c5"}), ({"c3", "c4"}, set())], None),
    ("fixer-poison", "fixer-poison", ["c1", "c2", "c3", "c4"], [({"c1"}, {"c4"}), ({"c2"}, set())], None),
    ("formula6", "named", ["c1", "c2", "c3", "c4", "c5", "c6"],
     [({"c1"}, {"c3"}), ({"c3", "c4"}, set()), ({"c5"}, set()), ({"c6"}, set())], f_formula6),
    ("n4-partner", "named", ["c1", "c2", "c3", "c4"], N4, f_n4),
    ("triple-across-halves", "named", ["c1", "c2", "c3", "c4"], [({"c1", "c2", "c3"}, set())], want(["c1", "c2", "c4"], c3="interaction")),
    ("n5-recover", "named", ["c1", "c2", "c3", "c4", "c5"], [({"c2"}, {"c5"}), ({"c3", "c4"}, set())], None),
    # a member green with the FINAL landed set must not stay ejected (the reviewer's two formulas)
    ("late-landing-a", "named", C6, [({"c2", "c5"}, set()), ({"c3", "c4"}, {"c6"})],
     want(["c1", "c2", "c3", "c4", "c6"], c5="interaction")),
    ("late-landing-b", "named", C6, [({"c4"}, {"c3"}), ({"c2", "c5"}, set()), ({"c1"}, {"c4"})], None),
    # N=5-6 from the families pair and fixer+pair
    ("n5-pair", "pair", ["c1", "c2", "c3", "c4", "c5"], [({"c1", "c4"}, set())], None),
    ("n6-pairs", "pair", C6, [({"c2", "c6"}, set()), ({"c3", "c5"}, set())], None),
    ("n5-fixer-pair", "fixer-pair", ["c1", "c2", "c3", "c4", "c5"], [({"c2"}, {"c5"}), ({"c1", "c3"}, set())], None),
    ("n6-fixer-pairs", "fixer-pair", C6, [({"c1"}, {"c6"}), ({"c3", "c4"}, set()), ({"c2", "c5"}, set())], None),
    ("n6-fixer-pair", "fixer-pair", C6, [({"c4"}, {"c2"}), ({"c1", "c6"}, set())], None),
    # red iff c2 or (c4,c5 without c1) or (c1,c6 without c5): a member ejected by the interaction search
    ("g4-interaction-ejectees", "named", C6, [({"c2"}, set()), ({"c4", "c5"}, {"c1"}), ({"c1", "c6"}, {"c5"})], None),
]
for nm, kind, fids, frules, fexp in FIXED:
    scenario(nm, kind, fids, frules, True, fexp)
    if nm in ("formula6", "triple-across-halves"):
        scenario(nm, kind, fids, frules, False)
    if nm == "n4-partner":  # reachable only with --no-recover: kills "interaction without the alone-green run"
        scenario(nm, kind, fids, frules, False, f_n4_norecover)
# the canary: the tool runs against RED-when-c2 rules but the test judges with other rules; the
# oracle must report problems, else it could not fail at all
cp = scenario("canary", "canary", ["c1", "c2", "c3"], [({"c2"}, set())], True, None, judge=[({"c3"}, set())])
res("oracle canary: a wrong predicate is DETECTED (%d problems)" % len(cp), [] if cp else ["the oracle found nothing wrong"])
for seed in range(nseeds):
    r = random.Random(seed)
    n = r.randint(2, nmax)
    ids = ["c%d" % i for i in r.sample(range(1, 7), n)]
    kind = KINDS[seed % len(KINDS)]
    if kind in ("triple", "fixer-pair") and n < 4 or kind == "triple" and n < 3:
        kind = "pair"
    if kind == "fixer-poison" and n < 3:
        kind = "fixer"
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
    elif kind == "fixer-pair":
        a, b, c, d = r.sample(ids, 4)
        rules = [({a}, {b}), ({c, d}, set())]
    elif kind == "fixer-poison":
        a, b, c = r.sample(ids, 3)
        rules = [({a}, {b}), ({c}, set())]
    elif kind == "red":
        rules = [(set(), set())]
    elif kind == "mixed":
        a, b, c = (r.sample(ids, 3) + ids)[:3] if n >= 3 else (ids[0], ids[1], ids[1])
        rules = [({a}, set()), ({b, c}, set())] if b != c else [({a}, set())]
    scenario("seed %d" % seed, kind, ids, rules, seed % 4 != 3)

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
if [ -n "${TRAIN_ORACLE_FULL:-}" ]; then ORC_DEF=60 ORC_MAX=6; else ORC_DEF=0 ORC_MAX=4; fi
ORC_N=${ORC_N:-$ORC_DEF}
ORC=$(cd "$S" && python3 -I -B "$S/oracle.py" "$SCRIPT" "$S" "$ORC_N" "$ORC_MAX" 2>&1)
while IFS= read -r ol; do
    case $ol in
    PASS*) ok ;;
    *) bad "${ol:0:300}" ;;
    esac
done <<<"$ORC"
check "oracle: ran the 9 fixed scenarios, $ORC_N generated ones and the state cases" test "$(count_of "$ORC" PASS)" -ge "$((ORC_N + 27))"

fi # oracle
if sec table; then
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
        # default: every position of 4; TRAIN_ORACLE_FULL=1 adds one first-half and one
        # second-half position of 8; TABLE_FULL=1 (with it) sweeps all 8
        if [ "$N" = 8 ] && [ -z "${TRAIN_ORACLE_FULL:-}" ]; then continue; fi
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
fi # table

# ============================================================================================
# The caller's repository is READ-ONLY input. Planted programs append their name to $PLOG, a
# file outside every repository; whatever the caller's config says, that log must stay empty.
# ============================================================================================
NEW=
for sname in allcfg callers sigmid sweep iso rm state unrel fs newc; do sec "$sname" && NEW=1; done
if [ -n "$NEW" ]; then
cat >"$S/helper.py" <<'PYEOF'
import hashlib, json, os, random, signal, subprocess, sys, time

G = os.environ["REAL_GIT"]


def snap(dirs, skip_objects=False):
    out = {}
    for di, d in enumerate(dirs):
        for root, dnames, fnames in os.walk(d, followlinks=False):
            rel = os.path.relpath(root, d)
            for n in dnames + fnames:
                p = os.path.join(root, n)
                key = "%d:%s" % (di, os.path.normpath(os.path.join(rel, n)))
                if skip_objects and key.startswith("0:.git/objects"):
                    continue
                st = os.lstat(p)
                if os.path.islink(p):
                    rec = ["l", os.readlink(p)]
                elif os.path.isdir(p):
                    rec = ["d", st.st_mode & 0o7777]
                else:
                    with open(p, "rb") as fh:
                        h = hashlib.sha256(fh.read()).hexdigest()
                    rec = ["f", st.st_size, st.st_mode & 0o7777, st.st_mtime_ns, h]
                out[key] = rec
    return out


def diffs(b, a, branch=None, objects=False):
    """Differences not explained by the one allowed write (new objects, the new ref and its log)."""
    bad = []
    for k in sorted(set(b) | set(a)):
        if b.get(k) == a.get(k):
            continue
        di, rel = k.split(":", 1)
        ok = False
        if (di == "0" and rel.startswith(".git/objects/") and k in b and k in a and b[k][0] == "f"
                and a[k][0] == "f" and b[k][1] == a[k][1] and b[k][4] == a[k][4]):
            continue  # an identical object/pack file written again (same name = same content)
        if di == "0" and k not in b:
            if (branch is not None or objects) and rel.startswith(".git/objects/"):
                ok = True
            if branch is not None and (rel == ".git/refs/heads/" + branch or rel.startswith(".git/logs/")):
                ok = True
        if di == "0" and branch is not None and rel == ".git/packed-refs":
            ok = True
        if not ok:
            bad.append("%s %s" % ("added" if k not in b else "removed" if k not in a else "changed", rel))
    return bad


def git(repo, *a, check=True):
    env = dict(os.environ, SPY_OFF="1")
    return subprocess.run([G, "-c", "core.fsmonitor=false", "-C", repo] + list(a), capture_output=True,
                          text=True, env=env, check=check, stdin=subprocess.DEVNULL).stdout


def main():
    cmd = sys.argv[1]
    if cmd == "snap":
        out, dirs = sys.argv[2], sys.argv[3:]
        skip = False
        if dirs and dirs[0] == "--skip-objects":
            skip, dirs = True, dirs[1:]
        json.dump(snap(dirs, skip), open(out, "w"))
    elif cmd == "cmp":
        b = json.load(open(sys.argv[2]))
        a = json.load(open(sys.argv[3]))
        branch = sys.argv[4] if len(sys.argv) > 4 and sys.argv[4] not in ("", "-") else None
        objects = len(sys.argv) > 5 and sys.argv[5] == "objects"
        bad = diffs(b, a, branch, objects)
        print("\n".join(bad[:8]))
        sys.exit(1 if bad else 0)
    elif cmd == "sweep":
        script, caller, tmpdir, n, seed, verify, logdir = sys.argv[2:9]
        cands = sys.argv[9:]
        n, rng = int(n), random.Random(int(seed))
        env = dict(os.environ)
        env.pop("SPY_OFF", None)
        env["TMPDIR"] = tmpdir

        ready = os.path.join(tmpdir, "..", "sweep-ready")

        def tool(delay, sig):
            t0 = time.time()
            if os.path.exists(ready):
                os.unlink(ready)
            env["TRAIN_SELFTEST"] = "1"
            env["TRAIN_TEST_READY_FILE"] = ready
            p = subprocess.Popen([sys.executable, "-I", "-B", script, "--base", "main", "--repo", caller,
                                  "--verify", verify, "--keep", "--log-dir", logdir] + cands,
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, env=env)
            sent = False
            early = False
            if delay is not None:
                time.sleep(delay)
                if p.poll() is None:
                    early = not os.path.exists(ready)  # the handlers are not installed yet
                    p.send_signal(sig)
                    sent = True
            out = p.communicate(timeout=60)[0].decode("utf-8", "replace")
            return p.returncode, (sent, early), time.time() - t0, out

        def drop_branches():
            for ln in git(caller, "for-each-ref", "--format=%(refname) %(objectname)", "refs/heads/train-*").split("\n"):
                if ln:
                    git(caller, "update-ref", "-d", ln.split()[0])

        base = git(caller, "rev-parse", "main").strip()
        rc, _, dur, _ = tool(None, None)
        drop_branches()
        hits = 0
        names = {signal.SIGHUP: 129, signal.SIGINT: 130, signal.SIGTERM: 143}
        sigs = [signal.SIGHUP, signal.SIGINT, signal.SIGTERM]
        for i in range(n):
            sig = sigs[i % 3]
            delay = rng.uniform(0, 1.15 * dur)
            before = snap([caller])
            refs0 = git(caller, "for-each-ref")
            rc, (sent, early), _, out = tool(delay, sig)
            after = snap([caller])
            probs = []
            # BEFORE the ready file exists the interpreter may still be starting: 128+n (handler) OR death
            # by the signal (rc == -n, the shell reports 128+n for both). AFTER ready: 128+n, or the
            # documented outcome of a run that finished first (0 / 1).
            ok_rc = (names[sig], -int(sig)) if early else (0, 1, names[sig])
            if rc not in ok_rc:
                probs.append("exit %d after signal %s (%s ready)" % (rc, sig.name, "before" if early else "after"))
            if sent and rc == names[sig]:
                hits += 1
            left = [x for x in os.listdir(tmpdir) if x.startswith("itrain-")]
            if left:
                probs.append("left %s" % left)
                os.makedirs(os.path.join(tmpdir, "..", "leftovers"), exist_ok=True)
                for x in left:  # one leftover fails one signal, not every later one
                    os.rename(os.path.join(tmpdir, x), os.path.join(tmpdir, "..", "leftovers", "%d-%s" % (i, x)))
            brs = [x for x in git(caller, "for-each-ref", "--format=%(refname:short) %(objectname)",
                                  "refs/heads/train-*").split("\n") if x]
            if len(brs) > 1:
                probs.append("more than one branch %s" % brs)
            branch = None
            if brs:
                branch, sha = brs[0].split()
                if (subprocess.run([G, "-C", caller, "cat-file", "-e", sha + "^{tree}"]).returncode != 0
                        or subprocess.run([G, "-C", caller, "rev-list", "--objects", sha, "^" + base],
                                          capture_output=True).returncode != 0):
                    probs.append("a branch %s whose objects are incomplete" % branch)
            probs += diffs(before, after, branch, True)[:3]
            drop_branches()
            if git(caller, "for-each-ref") != refs0:
                probs.append("refs differ from before after cleanup")
            print(("FAIL" if probs else "PASS"), "sweep %d %s delay=%.3f rc=%d%s" % (
                i, sig.name, delay, rc, ": " + "; ".join(probs) if probs else ""))
        print("HITS %d %d" % (hits, n))


main()
PYEOF
HELPER=("python3" -I -B "$S/helper.py")
mkdir -p "$S/spy" "$S/elsewhere"
echo keep >"$S/elsewhere/keep.txt"
mkspy() { # name [body]: a planted program: logs its name unless SPY_OFF, then runs the body
    printf '#!/bin/sh\n[ -n "${SPY_OFF:-}" ] || echo "%s" >>"%s"\n%s\n' "$1" "$PLOG" "${2:-cat}" >"$S/spy/$1"
    chmod +x "$S/spy/$1"
}
plog_empty() { [ "$(wc -c <"$PLOG" | tr -d ' ')" = 0 ]; }
: >"$PLOG"

mk_caller() { # DIR [object-format]: a non-bare repo with the standard branches, nothing planted
    local d=$1 fmt=${2:-}
    "$REAL_GIT" init -q -b main ${fmt:+--object-format=$fmt} "$d" || return 1
    {
        printf 'commit refs/heads/main\nmark :1\ncommitter t <t@x> 1700000000 +0000\ndata <<EOF\nbase\nEOF\n'
        fi_file f.txt "$(printf 'l1\nl2\nl3')"
        fi_file m.mrg "$(printf 'm1\nm2\nm3')"
        fi_file a.dat dat
        fi_file p.prc prc
        fi_file dir/one.txt one
        fi_file dir/two.txt two
        fi_file .gitattributes "$(printf '*.txt filter=spy\n*.dat filter=y diff=dx\n*.mrg merge=x\n*.prc filter=prc')"
        fi_commit hg "add g1" :1 "g1.txt=ok"
        fi_commit g2 "add f2" :1 "f2.txt=ok 2"
        fi_commit g4 "add f4" :1 "f4.txt=ok 4"
        fi_commit hx "poison" :1 "f9.txt=POISON"
        fi_commit fa "flag a" :1 "a.flag=a"
        fi_commit fb "flag b" :1 "b.flag=b"
        fi_commit hcf "conf side" :1 "f.txt=$(printf 'l1\nCF\nl3')"
        fi_commit hms "ms one" :1 "ms1.txt=1"
        fi_commit hms "ms two" "" "ms2.txt=2"
        fi_commit msq "msq one" :1 "q1.txt=1"
        fi_commit msq "msq two" "" "m.mrg=$(printf 'm1\nMSIDE\nm3')"
        fi_commit ad "adds inside dir" :1 "dir/new.txt=new"
        printf 'commit refs/heads/rd\ncommitter t <t@x> 1700000000 +0000\ndata <<EOF\nrename dir\nEOF\nfrom :1\nR dir dir2\n'
        fi_commit rt "unrelated root" "" "r.txt=root"
        fi_commit main "base moves" "" "f.txt=$(printf 'l1\nBASE2\nl3')" "m.mrg=$(printf 'm1\nMBASE\nm3')"
    } >"$d.stream"
    "$REAL_GIT" -C "$d" fast-import --quiet <"$d.stream" || return 1
    "$REAL_GIT" -C "$d" reset -q --hard
}
mk_signed() { # DIR: branch sg = two commits carrying a gpgsig header, on the first commit of main
    local d=$1 g=("$REAL_GIT" -C "$1") parent tree n blob
    parent=$("${g[@]}" rev-parse main~1)
    for n in 1 2; do
        blob=$(printf '%s' "$n" | "${g[@]}" hash-object -w --stdin)
        tree=$({ "${g[@]}" ls-tree "$parent"; printf '100644 blob %s\tsg%s.txt\n' "$blob" "$n"; } | "${g[@]}" mktree)
        parent=$(printf 'tree %s\nparent %s\nauthor t <t@x> 1700000000 +0000\ncommitter t <t@x> 1700000000 +0000\ngpgsig -----BEGIN PGP SIGNATURE-----\n \n abc\n -----END PGP SIGNATURE-----\n\nsigned %s\n' \
            "$tree" "$parent" "$n" | "${g[@]}" hash-object -t commit -w --stdin)
    done
    "${g[@]}" update-ref refs/heads/sg "$parent"
}
HOOKS="applypatch-msg pre-applypatch post-applypatch pre-commit pre-merge-commit prepare-commit-msg commit-msg post-commit pre-rebase post-checkout post-merge pre-push pre-auto-gc post-rewrite reference-transaction push-to-checkout post-index-change fsmonitor-watchman proc-receive pre-receive update post-receive post-update sendemail-validate"
SUBS="rev-parse config init update-ref worktree status cherry-pick merge commit diff log ls-files ls-tree merge-base rev-list pack-objects index-pack cat-file fetch clone"
plant() { # DIR [light]: EVERYTHING that can run a program, in the caller's config
    local d=$1 light=${2:-} C=$1/.git/config h n
    local cfg=("$REAL_GIT" config -f "$C")
    for h in $HOOKS; do mkspy "hook-$h" 'exit 0'; cp "$S/spy/hook-$h" "$d/.git/hooks/$h"; done
    for n in ssh editor seqeditor pager cred fclean fsmudge yclean ysmudge textconv; do mkspy "$n"; done
    for n in fprocess yprocess gpg gpgssh gpgx509; do mkspy "$n" 'exit 1'; done
    mkspy fsmonitor 'printf "tok\\0"'
    mkspy diffext 'exit 0'
    mkspy x 'printf resolved >"$2"'
    mkspy mx 'printf resolved >"$2"'
    mkspy xwt 'printf resolved >"$2"'
    for n in $SUBS; do mkspy "alias-$n"; "${cfg[@]}" "alias.$n" "!$S/spy/alias-$n"; done
    printf '[filter "y"]\n\tclean = %s/spy/yclean\n\tsmudge = %s/spy/ysmudge\n\tprocess = %s/spy/yprocess\n\trequired = true\n[merge "x"]\n\tdriver = %s/spy/xwt %%O %%A %%B\n' \
        "$S" "$S" "$S" "$S" >"$S/inc_wt.cfg"
    printf '[diff "dz"]\n\ttextconv = %s/spy/textconv\n[merge "mz"]\n\tdriver = %s/spy/mx %%O %%A %%B\n' "$S" "$S" >"$S/inc.cfg"
    printf '*.txt filter=spy\n*.zzz diff=dx\n' >"$S/gattr"
    printf '*.log\n' >"$S/excl"
    "${cfg[@]}" core.hooksPath "$d/.git/hooks"
    "${cfg[@]}" core.sshCommand "$S/spy/ssh"
    "${cfg[@]}" core.editor "$S/spy/editor"
    "${cfg[@]}" sequence.editor "$S/spy/seqeditor"
    "${cfg[@]}" core.pager "$S/spy/pager"
    "${cfg[@]}" credential.helper "$S/spy/cred"
    "${cfg[@]}" 'url.http://rewrite.invalid/.insteadOf' /
    "${cfg[@]}" safe.directory '*'
    "${cfg[@]}" core.attributesFile "$S/gattr"
    "${cfg[@]}" core.excludesFile "$S/excl"
    "${cfg[@]}" filter.spy.clean "$S/spy/fclean"
    "${cfg[@]}" filter.spy.smudge "$S/spy/fsmudge"
    "${cfg[@]}" filter.spy.required true
    "${cfg[@]}" merge.x.driver "$S/spy/x %O %A %B"
    "${cfg[@]}" merge.mx.driver "$S/spy/mx %O %A %B"
    "${cfg[@]}" diff.dx.command "$S/spy/diffext"
    "${cfg[@]}" diff.dx.textconv "$S/spy/textconv"
    "${cfg[@]}" diff.external "$S/spy/diffext"
    "${cfg[@]}" log.showSignature true
    "${cfg[@]}" merge.verifySignatures true
    "${cfg[@]}" gpg.program "$S/spy/gpg"
    "${cfg[@]}" gpg.ssh.program "$S/spy/gpgssh"
    "${cfg[@]}" gpg.x509.program "$S/spy/gpgx509"
    "${cfg[@]}" remote.origin.url https://example.invalid/r.git
    "${cfg[@]}" include.path "$S/inc.cfg"
    "${cfg[@]}" 'includeIf.gitdir:**/worktrees/**.path' "$S/inc_wt.cfg"
    "${cfg[@]}" 'includeIf.gitdir/i:**.path' "$S/inc.cfg"
    "${cfg[@]}" 'includeIf.onbranch:**.path' "$S/inc.cfg"
    "${cfg[@]}" 'includeIf.hasconfig:remote.*.url:*.path' "$S/inc.cfg"
    if [ -z "$light" ]; then
        "${cfg[@]}" core.fsmonitor "$S/spy/fsmonitor"
        "${cfg[@]}" filter.prc.process "$S/spy/fprocess"  # a failing process filter stops any git run,
        "${cfg[@]}" filter.prc.required true  # so only the caller under test gets it, never the control
        "${cfg[@]}" core.repositoryformatversion 1
        "${cfg[@]}" extensions.worktreeConfig true
        "${cfg[@]}" core.worktree "$S/elsewhere"
        printf '[filter "wt"]\n\tclean = %s/spy/yclean\n[merge "wx"]\n\tdriver = %s/spy/xwt %%O %%A %%B\n' "$S" "$S" >"$d/.git/config.worktree"
    fi
}
AC=$S/ac
CTL=$S/ctl
need_ac() {
    [ -d "$AC" ] && return 0
    mk_caller "$AC" && mk_signed "$AC" && plant "$AC"
}
ident_text() { # the caller's refs and status as text (planted programs gated off)
    SPY_OFF=1 GIT_OPTIONAL_LOCKS=0 "$REAL_GIT" -c core.fsmonitor=false -C "$1" for-each-ref 2>&1
    SPY_OFF=1 GIT_OPTIONAL_LOCKS=0 "$REAL_GIT" -c core.fsmonitor=false -C "$1" status --porcelain=v2 --branch 2>&1
    SPY_OFF=1 "$REAL_GIT" -c core.fsmonitor=false -C "$1" worktree list 2>&1
}
ID_BEFORE=
ident_begin() { # caller dir
    "${HELPER[@]}" snap "$S/ib.json" "$1" "$S/elsewhere"
    ID_BEFORE=$(ident_text "$1")
}
ident_end() { # desc, caller dir, [objects]  (the landed branch $BR, if any, is the one allowed write)
    local d=$2 bad
    "${HELPER[@]}" snap "$S/ia.json" "$d" "$S/elsewhere"
    bad=$("${HELPER[@]}" cmp "$S/ib.json" "$S/ia.json" "${BR:--}" "${3:-}")
    check "$1: caller byte-identical except the new branch and its objects${bad:+ ($bad)}" eq "$bad" ""
    [ -n "$BR" ] && SPY_OFF=1 "$REAL_GIT" -C "$d" update-ref -d "refs/heads/$BR"
    check "$1: refs, status, worktree list identical after dropping the new branch" eq "$(ident_text "$d")" "$ID_BEFORE"
}
fi

if sec allcfg; then
need_ac
mk_caller "$CTL" && mk_signed "$CTL" && plant "$CTL" light
# -- controls: the planted programs are REAL; git run directly in the caller's config fires them
: >"$PLOG"
CG=("$REAL_GIT" -C "$CTL" -c user.name=t -c user.email=t@x)
"${CG[@]}" commit -q --allow-empty -m ctl >/dev/null 2>&1
echo more >"$CTL/new.txt"
"${CG[@]}" add new.txt >/dev/null 2>&1
rm "$CTL/f.txt"
"${CG[@]}" checkout -q -- f.txt >/dev/null 2>&1
"${CG[@]}" log -1 --show-signature sg >/dev/null 2>&1
"${CG[@]}" -c core.fsmonitor="$S/spy/fsmonitor" status >/dev/null 2>&1
"${CG[@]}" -c merge.verifySignatures=false merge -q --no-edit msq >/dev/null 2>&1
"${CG[@]}" worktree add -q --detach "$S/ctlwt" main >/dev/null 2>&1
CTLOG=$(cat "$PLOG")
for want in hook-pre-commit hook-commit-msg hook-reference-transaction fclean fsmudge gpg fsmonitor x; do
    check "control: the planted $want fires when git runs directly in the caller's config" has "$CTLOG" "$want"
done
check "control: the includeIf gitdir:**/worktrees/** filter (y.process) runs inside a linked worktree" has "$CTLOG" yprocess
check "control: the signed-looking branch is really signed-looking" has "$("$REAL_GIT" -C "$CTL" cat-file commit sg)" "gpgsig"
: >"$PLOG"

# -- the tool, five paths plus the round-2 repros, on the caller with EVERYTHING planted
for mode in green red conflict squash recovery signed; do
    case $mode in
    green) set -- hg hms ;;
    red) set -- hg hx hms ;;
    conflict) set -- hg hcf ;;
    squash) set -- msq hg ;;
    recovery) set -- fa g2 fb g4 ;;
    signed) set -- sg hg ;;
    esac
    ident_begin "$AC"
    REPOARG=$AC trn --keep "$@"
    check "allcfg $mode: the planted-program log is EMPTY" plog_empty
    case $mode in
    green)
        check "allcfg green: exit 0, both landed" has "$JSON" '"landed":["hg","hms"]' ;;
    red)
        check "allcfg red: bisect ejected hx" has "$JSON" '"id":"hx","why":"red"'
        check "allcfg red: the others landed" has "$JSON" '"landed":["hg","hms"]' ;;
    conflict)
        check "allcfg conflict: hcf ejected conflict" has "$JSON" '"id":"hcf","why":"conflict"'
        check "allcfg conflict: hg landed" has "$JSON" '"landed":["hg"]' ;;
    squash)
        check "allcfg squash: the conflict a planted merge driver 'resolved' is now a conflict ejection" has "$JSON" '"id":"msq","why":"conflict"'
        check "allcfg squash: only hg landed (nothing resolved by a driver)" has "$JSON" '"landed":["hg"]' ;;
    recovery)
        check "allcfg recovery: g4 recovered" has "$JSON" '"landed":["fa","g2","g4"]' ;;
    signed)
        check "allcfg signed: a signed-looking squash candidate landed" has "$JSON" '"landed":["sg","hg"]' ;;
    esac
    check "allcfg $mode: delivered a branch" test -n "$BR"
    ident_end "allcfg $mode" "$AC"
done
# round 2, blocker 1 verbatim: the landed squash of msq would have carried "resolved"
ident_begin "$AC"
REPOARG=$AC trn --keep msq
check "round-2 merge driver: a lone conflicting squash is exit 3 (nothing verified), not landed" eq "$RC" 3
check "round-2 merge driver: log empty" plog_empty
ident_end "round-2 merge driver" "$AC"
# a red-only run, an aborted run (unresolvable candidate), --state a directory: NO difference at all
ident_begin "$AC"
REPOARG=$AC trn --keep hx
check "allcfg red-only: nothing landed, no branch" has "$JSON" '"branch":""'
ident_end "allcfg red-only" "$AC"
ident_begin "$AC"
REPOARG=$AC trn --keep hg nosuch-branch
check "allcfg aborted: exit 2" eq "$RC" 2
ident_end "allcfg aborted" "$AC"
check "allcfg: the planted-program log is still EMPTY after every run" plog_empty
# the control for the identity check itself: a tool that touches the caller must fail it
ident_begin "$AC"
echo touched >"$AC/.git/itrain-touch"
"${HELPER[@]}" snap "$S/ia.json" "$AC" "$S/elsewhere"
check "identity control: one file written into the caller's .git IS detected" bash -c "! python3 -I -B '$S/helper.py' cmp '$S/ib.json' '$S/ia.json' - >/dev/null"
mv "$AC/.git/itrain-touch" "$S/touched"
fi

if sec callers; then
# -- a partial clone is refused with one line, and nothing of the caller's runs
PC=$S/pc
mk_caller "$PC"
mkspy uploadpack 'exit 1'
"$REAL_GIT" -C "$PC" config core.repositoryformatversion 1
"$REAL_GIT" -C "$PC" config extensions.partialclone origin
"$REAL_GIT" -C "$PC" config remote.origin.url "$S/nowhere.git"
"$REAL_GIT" -C "$PC" config remote.origin.promisor true
"$REAL_GIT" -C "$PC" config remote.origin.partialclonefilter blob:none
"$REAL_GIT" -C "$PC" config remote.origin.uploadpack "$S/spy/uploadpack"
: >"$PLOG"
REPOARG=$PC trn --keep hg
check "partial clone: exit 2" eq "$RC" 2
check "partial clone: one line" eq "$(count_of "$OUT" $'\n')" 0
check "partial clone: says why" has "$OUT" "partial clone"
check "partial clone: nothing ran (no uploadpack, no program)" plog_empty
check "partial clone: no temp dir left" eq "$(ls "$S/tmp" | wc -l | tr -d ' ')" 0
# a shallow caller is refused the same way
SH=$S/shallow
"$REAL_GIT" clone -q --depth 1 "file://$S/pc" "$SH" 2>/dev/null
REPOARG=$SH BASE=origin/main trn --keep origin/hg
check "shallow clone: exit 2, one line, names it" eq "$RC$(count_of "$OUT" $'\n')$(has "$OUT" shallow && echo y)" "20y"
# -- a caller with its own alternates (and one whose alternate has alternates) works
ALT1=$S/alt1
ALT2=$S/alt2
"$REAL_GIT" clone -q --shared "$BARE" "$ALT1"
"$REAL_GIT" -C "$ALT1" branch g1 origin/g1
"$REAL_GIT" -C "$ALT1" branch g2 origin/g2
"$REAL_GIT" clone -q --shared "$ALT1" "$ALT2"
check "alternates: the caller really has an alternates file" test -s "$ALT2/.git/objects/info/alternates"
REFS_BARE=$("$REAL_GIT" -C "$BARE" for-each-ref)
REPOARG=$ALT2 BASE=origin/main trn --keep origin/g1 origin/g2
check "alternates (depth 2): exit 0, both landed" has "$JSON" '"landed":["origin/g1","origin/g2"]'
check "alternates: the branch is in the caller (alt2) and complete" "$REAL_GIT" -C "$ALT2" cat-file -e "$BR^{tree}"
check "alternates: nothing was written into the repositories the alternates point at" eq "$("$REAL_GIT" -C "$BARE" for-each-ref)" "$REFS_BARE"
check "alternates: the new objects are in alt2's own store, not in alt1's" bash -c "! $REAL_GIT -C $ALT1 cat-file -e $BR 2>/dev/null"
# -- a bare caller, a caller given as a subdirectory
REFS_BARE=$("$REAL_GIT" -C "$BARE" for-each-ref)
REPOARG=$BARE trn --keep g1 g2
check "bare caller: lands, branch delivered into the bare repo" has "$JSON" '"landed":["g1","g2"]'
check "bare caller: the branch is there" "$REAL_GIT" -C "$BARE" cat-file -e "refs/heads/$BR"
"$REAL_GIT" -C "$BARE" update-ref -d "refs/heads/$BR"
check "bare caller: refs identical after dropping it" eq "$("$REAL_GIT" -C "$BARE" for-each-ref)" "$REFS_BARE"
SD=$S/sd
mk_caller "$SD"
mkdir -p "$SD/deep/er"
REPOARG=$SD/deep/er trn --keep hg
check "--repo a subdirectory: works (the repository is found above it)" has "$JSON" '"landed":["hg"]'
check "--repo a subdirectory: branch delivered" "$REAL_GIT" -C "$SD" cat-file -e "refs/heads/$BR"
check "--repo a subdirectory: no stray .git or file was created inside it" eq "$(ls -A "$SD/deep/er" | wc -l | tr -d ' ')" 0
# -- a sha256 caller works (or git cannot make one: skipped)
if "$REAL_GIT" init -q --object-format=sha256 "$S/s256probe" >/dev/null 2>&1; then
    mk_caller "$S/s256" sha256
    REPOARG=$S/s256 trn --keep hg g2
    check "sha256 caller: lands" has "$JSON" '"landed":["hg","g2"]'
    check "sha256 caller: the branch is a 64-hex commit in the caller" eq "${#BR}$("$REAL_GIT" -C "$S/s256" rev-parse "refs/heads/$BR" | tr -d '\n' | wc -c | tr -d ' ')" "${#BR}64"
else
    skip "sha256 caller (this git cannot create one)"
fi
fi

if sec iso; then
# verify isolation: state kept in ../ or in $TMPDIR must not flow between runs. x2 is red alone;
# the verify turns GREEN as soon as it sees a leaked file, so any sharing lands x2 for real.
for where in '../leak' '$TMPDIR/leak'; do
    LK=$(printf '%s' "$where")
    V='if [ -f '"$where"' ]; then echo seen; exit 0; fi; touch '"$where"'; if grep -rq POISON .; then echo FAIL poison; exit 1; fi; exit 0'
    begin
    trn --keep x2 g1
    check "isolation ($LK): the red candidate stays ejected (its OWN run saw no leaked file)" has "$JSON" '"id":"x2","why":"red"'
    check "isolation ($LK): the innocent candidate landed" has "$JSON" '"landed":["g1"]'
    # item 0: x2 (red alone) is retried once with the landed g1: its OWN record says red_with [g1] AND
    # verified_red_alone; a leaked file would have made that retry green and landed x2
    check "isolation ($LK): the red-alone member's red_with is the honest one" has "$JSON" '"red_with":["g1"]'
    check "isolation ($LK): and it stays red alone" has "$JSON" '"verified_red_alone":true'
    check "isolation ($LK): exactly one red_with in the report" eq "$(count_of "$JSON" red_with)" 1
    finish "isolation ($LK)"
done
unset V
# stdin: the harness leaves a line on the tool's stdin; no git call and no verify may be able to read it
echo SENTINEL >"$S/sentinel"
: >"$GITLOG"
WRAP=1 TSTDIN=$S/sentinel V='if IFS= read -r -t 1 _x; then echo FAIL stdin; exit 1; fi; true' trn --keep g1 g2
check "stdin: the verify command sees /dev/null (green)" has "$JSON" '"landed":["g1","g2"]'
check "stdin: the run really went through the recording git" has "$(cat "$GITLOG")" worktree
check "stdin: no git call could read the line left on the tool's stdin" lacks "$(cat "$GITLOG")" STDIN-READABLE
finish "stdin"
unset V
fi

if sec rm; then
# a verify that leaves mode-000 directories, a read-only tree, and a symlink at a canary
mkdir -p "$S/canary/sub"
echo precious >"$S/canary/sub/file"
chmod 0555 "$S/canary"
V='mkdir -p dd/ee "$TMPDIR/t"; echo x >dd/ee/f; ln -s '"$S"'/canary dd/link; ln -s '"$S"'/canary "$TMPDIR/link2"; chmod -R a-w . 2>/dev/null; chmod 000 dd/ee dd "$TMPDIR/t"; exit 0'
begin
trn --keep g1
check "unremovable leftovers: the run still lands" has "$JSON" '"landed":["g1"]'
check "unremovable leftovers: the private root is removed anyway" eq "$(ls "$S/tmp" | wc -l | tr -d ' ')" 0
check "symlink canary: the file behind the link survives" test -f "$S/canary/sub/file"
check "symlink canary: its mode was not touched (not followed by chmod)" eq "$(ls -ld "$S/canary" | cut -c1-10)" "dr-xr-xr-x"
finish "unremovable leftovers"
chmod 0755 "$S/canary"
unset V
fi

if sec state; then
begin
mkdir -p "$S/adir"
: >"$S/ctr0"
V='echo x >>'"$S"'/ctr0; true' trn --state "$S/adir" g1
check "--state a directory: exit 2" eq "$RC" 2
check "--state a directory: refused AT THE START, verify never ran" eq "$(wc -c <"$S/ctr0" | tr -d ' ')" 0
check "--state a directory: nothing was put inside it" eq "$(ls -A "$S/adir" | wc -l | tr -d ' ')" 0
check "--state a directory: no temp dir left" eq "$(ls "$S/tmp" | wc -l | tr -d ' ')" 0
mkdir -p "$S/rodir"
chmod 0555 "$S/rodir"
V='echo x >>'"$S"'/ctr0; true' trn --state "$S/rodir/state" g1
if [ -w "$S/rodir" ]; then skip "--state unwritable dir (running as a user who can write anywhere)"; else
    check "--state in an unwritable directory: exit 2 at the start" eq "$RC" 2
    check "--state in an unwritable directory: verify never ran" eq "$(wc -c <"$S/ctr0" | tr -d ' ')" 0
fi
chmod 0755 "$S/rodir"
finish "--state refusals"
# atomic replace: a hard link to the old state file keeps the OLD content (in place would change it)
printf '{"next":3}' >"$S/astate"
ln "$S/astate" "$S/astate.link"
trn --state "$S/astate" g1
check "state is replaced atomically: the old inode is untouched" eq "$(cat "$S/astate.link")" '{"next":3}'
check "state is replaced atomically: the new content is in place" has "$(cat "$S/astate")" '"next":4'
check "state: no temp file left beside it" eq "$(printf '%s\n' "$S"/astate.tmp* | grep -c 'astate.tmp[^*]')" 0
fi

if sec unrel; then
need_ac
ident_begin "$AC"
REPOARG=$AC trn --keep hg rt g2
check "unrelated history: the candidate is ejected 'unrelated', not an abort" has "$JSON" '"id":"rt","why":"unrelated"'
check "unrelated history: the others land" has "$JSON" '"landed":["hg","g2"]'
check "unrelated history: exit 1" eq "$RC" 1
ident_end "unrelated history" "$AC"
# a directory rename plus a file added inside it: a conflict (or an honest clean apply), never a guess
REPOARG=$AC trn rd ad
case $JSON in
*'"id":"ad","why":"conflict"'*)
    AL=${JSON#*\"id\":\"ad\",\"why\":\"conflict\",\"log\":\"}
    AL=${AL%%\"*}
    check "dir rename + added file: the ejection message guesses no cause" eq "$(cat "$AL")" "does not apply cleanly on the joined tree" ;;
*) check "dir rename + added file: applied cleanly, both landed" has "$JSON" '"landed":["rd","ad"]' ;;
esac
check "dir rename + added file: the train did not abort" test "$RC" -le 1
fi

if sec fs; then
# filesystems that fold case / Unicode form cannot hold some trees; probe what THIS one does
: >"$S/FsProbe"
FS_CASE=
[ -e "$S/fsprobe" ] && FS_CASE=1
: >"$S/fsnfc-$(printf '\303\251')"
FS_NFD=
[ -e "$S/fsnfc-$(printf 'e\314\201')" ] && FS_NFD=1
if [ -n "$FS_CASE$FS_NFD" ]; then
    FSC=$S/fsc
    mk_caller "$FSC"
    {
        printf 'commit refs/heads/case\ncommitter t <t@x> 1700000000 +0000\ndata <<EOF\ncase twin\nEOF\nfrom refs/heads/main\n'
        fi_file F.TXT upper
        printf 'commit refs/heads/nfc\ncommitter t <t@x> 1700000000 +0000\ndata <<EOF\nnfc\nEOF\nfrom refs/heads/main\n'
        fi_file "$(printf 'caf\303\251.txt')" nfc
        printf 'commit refs/heads/nfd\ncommitter t <t@x> 1700000000 +0000\ndata <<EOF\nnfd\nEOF\nfrom refs/heads/main\n'
        fi_file "$(printf 'cafe\314\201.txt')" nfd
    } >"$S/fsc.stream"
    "$REAL_GIT" -C "$FSC" -c core.ignorecase=false fast-import --quiet --force <"$S/fsc.stream"
    REPOARG=$FSC trn --keep case nfc nfd hg
    if [ -n "$FS_CASE" ]; then
        check "filesystem: a case twin of an existing path is ejected unrepresentable" has "$JSON" '"id":"case","why":"unrepresentable-on-this-filesystem"'
    else skip "filesystem case twin (this filesystem keeps case)"; fi
    if [ -n "$FS_NFD" ]; then
        check "filesystem: the NFD twin of an admitted NFC name is ejected unrepresentable" has "$JSON" '"id":"nfd","why":"unrepresentable-on-this-filesystem"'
    else skip "filesystem NFC/NFD twin (this filesystem keeps Unicode forms apart)"; fi
    check "filesystem: the train did not fail; the representable ones landed" has "$JSON" '"hg"'
    check "filesystem: no 'not byte-clean' exit 2" test "$RC" -le 1
    "$REAL_GIT" -C "$FSC" update-ref -d "refs/heads/$BR"
    # a base that collides with itself: exit 2 naming both paths
    FSB=$S/fsb
    "$REAL_GIT" init -q -b main "$FSB"
    {
        printf 'commit refs/heads/main\ncommitter t <t@x> 1700000000 +0000\ndata <<EOF\ncolliding base\nEOF\n'
        fi_file Readme.md one
        fi_file README.MD two
        fi_commit c1 "c1" refs/heads/main "c1.txt=1"
    } >"$S/fsb.stream"
    "$REAL_GIT" -C "$FSB" -c core.ignorecase=false fast-import --quiet <"$S/fsb.stream"
    if [ -n "$FS_CASE" ]; then
        REPOARG=$FSB trn c1
        check "filesystem: a base that collides with itself is exit 2 naming both paths" eq "$RC$(has "$OUT" Readme.md && has "$OUT" README.MD && echo y)" "2y"
    else skip "filesystem self-colliding base (this filesystem keeps case)"; fi
else
    skip "filesystem collision cases (this filesystem is case-sensitive and keeps Unicode forms apart)"
fi
fi

if sec sigmid; then
need_ac
mkdir -p "$S/sigbin"
cat >"$S/sigbin/git" <<'XEOF'
#!/bin/bash
# HOOK_SUB + HOOK_SCOPE (caller|private) + HOOK_NTH pick ONE git call; HOOK_MODE now: signal the tool
# (our parent) INSTEAD of running it; delay: signal it HOOK_DELAY seconds into the real command.
args=("$@")
i=0
scope=caller
while [ "$i" -lt "${#args[@]}" ]; do
    case ${args[$i]} in
    -c | -C) i=$((i + 2)) ;;
    --git-dir=*) case ${args[$i]} in */repo.git) scope=private ;; *) scope=caller ;; esac; i=$((i + 1)) ;;
    *) break ;;
    esac
done
sub=${args[$i]:-}
if [ "$sub" = "${HOOK_SUB:-}" ] && [ "$scope" = "${HOOK_SCOPE:-}" ]; then
    n=$(($(cat "$HOOK_COUNT" 2>/dev/null) + 1))
    echo "$n" >"$HOOK_COUNT"
    if [ "$n" = "${HOOK_NTH:-1}" ]; then
        if [ "${HOOK_MODE:-now}" = now ]; then
            kill -"${HOOK_SIG:-TERM}" "$PPID"
            exec sleep 30
        fi
        (
            sleep "${HOOK_DELAY:-0.1}"
            kill -"${HOOK_SIG:-TERM}" "$PPID"
        ) >/dev/null 2>&1 &
    fi
fi
exec "$REAL_GIT" "$@"
XEOF
chmod +x "$S/sigbin/git"
# (a) a signal WHILE `git worktree add` checks out a big tree: nothing is left in the caller or TMPDIR
NBIG=5000
[ -n "${TRAIN_ORACLE_FULL:-}" ] && NBIG=40000
BIG=$S/big
"$REAL_GIT" init -q -b main "$BIG"
awk -v n="$NBIG" 'BEGIN {
    print "commit refs/heads/main\nmark :1\ncommitter t <t@x> 1700000000 +0000\ndata <<EOF\nbig\nEOF";
    for (i = 0; i < n; i++) printf "M 100644 inline d%d/f%d.txt\ndata 3\nx%d\n\n", i % 200, i, i % 10;
    print "commit refs/heads/bg1\ncommitter t <t@x> 1700000000 +0000\ndata <<EOF\nadd\nEOF\nfrom :1\nM 100644 inline new1.txt\ndata 2\nn\n";
}' >"$S/big.stream"
"$REAL_GIT" -C "$BIG" fast-import --quiet <"$S/big.stream"
"$REAL_GIT" -C "$BIG" reset -q --hard
"${HELPER[@]}" snap "$S/bb.json" "$BIG"
BIGW=$("$REAL_GIT" -C "$BIG" worktree list)
SGS=TERM
[ -n "${TRAIN_ORACLE_FULL:-}" ] && SGS="TERM INT HUP"
for sg in $SGS; do
    : >"$S/hc"
    SIGOK=1 WRAPDIR=$S/sigbin REPOARG=$BIG TENV="HOOK_SUB=worktree HOOK_SCOPE=private HOOK_NTH=1 HOOK_MODE=delay HOOK_DELAY=0.05 HOOK_SIG=$sg HOOK_COUNT=$S/hc" V=true trn --keep bg1
    case $sg in TERM) want=143 ;; INT) want=130 ;; HUP) want=129 ;; esac
    check "signal $sg during worktree add on $NBIG files: exit $want" eq "$RC" "$want"
    check "signal $sg during worktree add: no itrain-* left in TMPDIR" eq "$(ls "$S/tmp" | wc -l | tr -d ' ')" 0
    "${HELPER[@]}" snap "$S/ba.json" "$BIG"
    check "signal $sg during worktree add: the caller (every file, .git included) is byte-identical" "${HELPER[@]}" cmp "$S/bb.json" "$S/ba.json" -
    check "signal $sg during worktree add: git worktree list identical, no locked wt1" eq "$("$REAL_GIT" -C "$BIG" worktree list)" "$BIGW"
done
# (b) a signal exactly between "objects written to the caller" and "ref created"
ident_begin "$AC"
: >"$S/hc"
SIGOK=1 WRAPDIR=$S/sigbin REPOARG=$AC TENV="HOOK_SUB=update-ref HOOK_SCOPE=caller HOOK_NTH=1 HOOK_MODE=now HOOK_SIG=TERM HOOK_COUNT=$S/hc" trn --keep hg g2
check "signal between objects and ref: exit 143" eq "$RC" 143
BR=
ident_end "signal between objects and ref (only objects may differ)" "$AC" objects
check "signal between objects and ref: no train-* ref in the caller" eq "$("$REAL_GIT" -C "$AC" for-each-ref 'refs/heads/train-*' | wc -l | tr -d ' ')" 0
check "signal between objects and ref: no itrain-* left" eq "$(ls "$S/tmp" | wc -l | tr -d ' ')" 0
ident_begin "$AC"
REPOARG=$AC trn --keep hg g2
check "signal between objects and ref: a rerun succeeds" has "$JSON" '"landed":["hg","g2"]'
ident_end "rerun after the interrupted delivery" "$AC"
# (c) SIGKILL leaves exactly one itrain-* directory under TMPDIR and nothing in the caller
mkfifo "$S/kfifo"
ident_begin "$AC"
(cd "$WT" && exec python3 -I -B "$SCRIPT" --base main --repo "$AC" --log-dir "$S/logs" \
    --verify "echo go > $S/kfifo; sleep 3" hg g2) >"$S/kill.out" 2>&1 &
KPID=$!
exec 3<>"$S/kfifo"
read -t 8 -r _ <&3
exec 3>&-
kill -KILL "$KPID"
wait "$KPID" 2>/dev/null
BR=
ident_end "SIGKILL" "$AC"
KLEFT=$(cd "$S/tmp" && printf '%s ' itrain-*)
check "SIGKILL: exactly ONE itrain-* directory is left, nothing else in TMPDIR" eq "$(count_of "$KLEFT" itrain-)$(ls "$S/tmp" | wc -l | tr -d ' ')" "11"
KDIR=$(ls "$S/tmp" | head -n 1)
touch -t 202001010000 "$S/tmp/$KDIR"
KEEP_LEFT=1 REPOARG=$AC trn hg
check "SIGKILL: the next start prints ONE notice line about the stale directory" eq "$(count_of "$OUT" 'notice: 1 stale itrain-')" 1
check "SIGKILL: the notice does not delete it" test -d "$S/tmp/$KDIR"
mv "$S/tmp/$KDIR" "$S/killed-root"
check "signals: the planted-program log is EMPTY" plog_empty
fi

if sec sweep; then
need_ac
NSW=4
[ -n "${TRAIN_ORACLE_FULL:-}" ] && NSW=20
SWO=$("${HELPER[@]}" sweep "$SCRIPT" "$AC" "$S/tmp" "$NSW" 7 'sleep 0.05; sh '"$S"'/verify.sh' "$S/logs" hg hx hms g2)
while IFS= read -r ol; do
    case $ol in
    PASS*) ok ;;
    HITS*) set -- $ol
        check "sweep: at least a quarter of the $NSW signals landed mid-run (measured $2)" test "$((${2} * 4))" -ge "$NSW" ;;
    *) bad "${ol:0:300}" ;;
    esac
done <<<"$SWO"
check "sweep: the planted-program log is EMPTY after $NSW random signals" plog_empty
fi

if sec newc; then
# ---- the later tool changes: a private-repo snapshot per run, uncheckoutable content, flags,
# escaping, signals around delivery, item 0 (scratch repository NC, nothing planted) ----------
NC=$S/nc
GID='GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@x GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@x'
"$REAL_GIT" init -q -b main "$NC"
{
    printf 'commit refs/heads/main\nmark :1\ncommitter t <t@x> 1700000000 +0000\ndata <<EOF\nbase\nEOF\n'
    fi_file b.txt base
    for n in 1 2 3; do fi_commit "n$n" "add n$n" :1 "n$n.txt=file $n"; done
    fi_commit po "poison" :1 "po.txt=POISON"
    # d1/d2 both add a path with ESC, a newline and a tab (they overlap: the second is deferred)
    fi_commit d1 "esc one" :1 '"e\033x\ny\tz.txt"=1'
    fi_commit d2 "esc two" :1 '"e\033x\ny\tz.txt"=2'
} >"$S/nc.stream"
"$REAL_GIT" -C "$NC" fast-import --quiet <"$S/nc.stream"
"$REAL_GIT" -C "$NC" reset -q --hard
NCB=$("$REAL_GIT" -C "$NC" rev-parse main)
NCBLOB=$("$REAL_GIT" -C "$NC" rev-parse main:b.txt)
nc_commit() { # branch, tree entries (mktree lines)
    local t c
    t=$(printf '%b' "$2" | "$REAL_GIT" -C "$NC" mktree) || return 1
    c=$("$REAL_GIT" -C "$NC" -c user.name=t -c user.email=t@x commit-tree "$t" -p "$NCB" -m "$1") || return 1
    "$REAL_GIT" -C "$NC" update-ref "refs/heads/$1" "$c"
}
HI=$(echo hi | "$REAL_GIT" -C "$NC" hash-object -w --stdin)
SYM=$(printf '.gitmodules' | "$REAL_GIT" -C "$NC" hash-object -w --stdin)
GMOD=$(printf '[submodule "x"]\n\tpath = x\n\turl = ../x\n\tupdate = !echo hostile\n' | "$REAL_GIT" -C "$NC" hash-object -w --stdin)
ENCA=$(printf '*.dat working-tree-encoding=UTF-16\n' | "$REAL_GIT" -C "$NC" hash-object -w --stdin)
ENCB=$(printf 'caf\303\251 \377\376 broken\n' | "$REAL_GIT" -C "$NC" hash-object -w --stdin)
nc_commit dotgit "100644 blob $HI\t.git\n100644 blob $NCBLOB\tb.txt\n" # git refuses to check a .git entry out
nc_commit symgm "120000 blob $SYM\t.gitmodules\n100644 blob $NCBLOB\tb.txt\n" # a symlinked .gitmodules
nc_commit hostgm "100644 blob $GMOD\t.gitmodules\n100644 blob $NCBLOB\tb.txt\n" # update = !cmd
nc_commit enc "100644 blob $ENCA\t.gitattributes\n100644 blob $ENCB\tz.dat\n100644 blob $NCBLOB\tb.txt\n"
no_ctl() { ! printf '%s' "$1" | LC_ALL=C tr -d '\n' | LC_ALL=C grep -q '[[:cntrl:]]'; }
NCV='if grep -rq POISON . ; then echo FAIL poison; exit 1; fi; echo ok'

# (a) a verify that keeps state in the SHARED private repository voids the run: exit 2, nothing lands
for variant in config stash gitdir; do
    case $variant in
    config) VV='git config x.y z; echo ok' ;;
    stash) VV='echo dirty >>n1.txt; env '"$GID"' git stash -q; echo ok' ;;
    gitdir) VV='echo x >"$(git rev-parse --git-common-dir)/zz-state"; echo ok' ;;
    esac
    ident_begin "$NC"
    REPOARG=$NC V="$VV" trn --keep n1 n2
    check "snapshot ($variant): exit 2" eq "$RC" 2
    check "snapshot ($variant): the message names a change of the private repository" has "$OUT" "private repository"
    check "snapshot ($variant): nothing landed, nothing delivered" lacks "$OUT" '"landed":["'
    BR=
    ident_end "snapshot ($variant)" "$NC"
    check "snapshot ($variant): no itrain-* left" eq "$(ls "$S/tmp" | wc -l | tr -d ' ')" 0
done
ident_begin "$NC"
REPOARG=$NC V='echo x >inside.txt; mkdir -p "$TMPDIR/own"; echo y >"$TMPDIR/own/f"; echo ok' trn --keep n1 n2
check "snapshot control: a verify writing only inside its worktree and TMPDIR is fine" has "$JSON" '"landed":["n1","n2"]'
ident_end "snapshot control" "$NC"

# (b) content git itself refuses to check out: that candidate is ejected 'uncheckoutable', the rest land
for bc in dotgit symgm; do
    ident_begin "$NC"
    REPOARG=$NC V="$NCV" trn --keep n1 "$bc" n2
    check "uncheckoutable ($bc): exit 1, the others landed" eq "$RC$(has "$JSON" '"landed":["n1","n2"]' && echo y)" "1y"
    check "uncheckoutable ($bc): ejected with that reason and git's first error line" has "$JSON" '"id":"'"$bc"'","why":"uncheckoutable"'
    check "uncheckoutable ($bc): the error field is one line without a raw control byte" has "$JSON" '"error":"'
    check "uncheckoutable ($bc): the console output carries no raw control byte" no_ctl "$OUT"
    ident_end "uncheckoutable ($bc)" "$NC"
    check "uncheckoutable ($bc): no itrain-* left" eq "$(ls "$S/tmp" | wc -l | tr -d ' ')" 0
done
# the two inputs the first draft also claimed: measured, git does NOT fail for them, so they are
# ordinary candidates (the claim was dead and is gone from the tool)
ident_begin "$NC"
REPOARG=$NC V="$NCV" trn --keep hostgm n1
check "a .gitmodules with update = !cmd is NOT uncheckoutable (git checks it out): it lands" has "$JSON" '"landed":["hostgm","n1"]'
ident_end "hostile .gitmodules" "$NC"
ident_begin "$NC"
REPOARG=$NC V="$NCV" trn --keep n1 enc n2
ident_end "working-tree-encoding that does not convert" "$NC"
# measured: git does not fail for it either (it prints errors and exits 0 and the worktree is clean), so the
# candidate is verified and landed like any other; there is no 'uncheckoutable' path for it
check "unconvertible working-tree-encoding: git does not fail, the candidate is verified and lands (exit 0)" eq "$RC$(has "$JSON" '"landed":["n1","enc","n2"]' && echo y)" "0y"

# (c) a verify that leaves BSD file flags (macOS) must not keep the private root alive
if [ "$(uname)" = Darwin ] && command -v chflags >/dev/null 2>&1; then
    ident_begin "$NC"
    REPOARG=$NC V='echo x >fl; chflags uchg fl; mkdir fd; echo y >fd/g; chflags uchg fd/g fd; echo ok' trn --keep n1 n2
    check "chflags uchg on a file and a directory: the run is green" has "$JSON" '"landed":["n1","n2"]'
    check "chflags uchg: the private root is still removed" eq "$(ls "$S/tmp" | wc -l | tr -d ' ')" 0
    check "chflags uchg: no leftover field" lacks "$JSON" leftover
    ident_end "chflags uchg" "$NC"
    # a leftover that truly cannot be removed: an ACL that denies deleting a directory's children
    # (the remover clears modes and flags, not ACLs). The exit code stays what it was.
    REPOARG=$NC V='mkdir lk; echo x >lk/f; chmod +a "everyone deny delete,delete_child" lk; echo ok' trn n1 n2
    LEFT=$(cd "$S/tmp" && printf '%s ' itrain-*)
    if [ -d "$S/tmp/${LEFT%% *}" ] && [ "${LEFT#itrain-}" != "$LEFT" ]; then
        check "unremovable root: exit code unchanged (0, all landed)" eq "$RC" 0
        check "unremovable root: the JSON names it in leftover" has "$JSON" '"leftover":"'"$S"'/tmp/itrain-'
        check "unremovable root: ONE stderr line says so" eq "$(count_of "$OUT" 'could not remove the private root')" 1
        chmod -RN "$S/tmp/${LEFT%% *}" 2>/dev/null
        chmod -R u+rwx "$S/tmp/${LEFT%% *}" 2>/dev/null
        rm -rf -- "$S/tmp/${LEFT%% *}"
    else
        skip "unremovable root (this host's ACLs did not block the remover)"
    fi
else
    skip "chflags / unremovable-root cases (macOS only: no BSD file flags or ACLs here)"
fi

# (d) console escaping: a path with ESC, a newline and a tab shows up in a human-readable line
ident_begin "$NC"
REPOARG=$NC V="$NCV" trn --keep d1 d2
check "escaping: the console output carries no raw control byte" no_ctl "$OUT"
EXP=$'overlaps d1 on e\033x\ny\tz.txt'
check "escaping: the JSON still parses and carries the exact path" python3 -I -c '
import json, sys
d = json.loads(sys.argv[1])
sys.exit(0 if d["deferred"][0]["why"] == sys.argv[2] else 1)' "$JSON" "$EXP"
ident_end "escaping" "$NC"

# (e) a signal right after the delivered ref exists: stdout still names the branch and carries valid JSON
mkdir -p "$S/afterref"
cat >"$S/afterref/git" <<'XEOF'
#!/bin/bash
"$REAL_GIT" "$@"
rc=$?
case " $* " in *" update-ref refs/heads/train-"*) kill -TERM "$PPID" ;; esac
exit $rc
XEOF
chmod +x "$S/afterref/git"
ident_begin "$NC"
SIGOK=1 WRAPDIR=$S/afterref REPOARG=$NC V=true trn --keep n1 n2
check "signal after delivery: exit 143" eq "$RC" 143
check "signal after delivery: the branch line is printed" has "$OUT" "integration branch: train-"
check "signal after delivery: the last stdout line is valid JSON naming the branch" python3 -I -c '
import json, sys
d = json.loads(sys.argv[1].rsplit("\n", 1)[-1])
sys.exit(0 if d["branch"].startswith("train-") and d["landed"] == ["n1", "n2"] else 1)' "$OUT"
check "signal after delivery: the delivered branch exists and the caller's objects are connected" bash -c "'$REAL_GIT' -C '$NC' rev-parse -q --verify refs/heads/$BR >/dev/null && '$REAL_GIT' -C '$NC' fsck --connectivity-only >/dev/null 2>&1"
check "signal after delivery: no itrain-* left" eq "$(ls "$S/tmp" | wc -l | tr -d ' ')" 0
ident_end "signal after delivery" "$NC" objects

# (f) EARLY signals, deterministic: the tool pauses right after its handlers are installed and writes the
# ready file first; a signal sent once it exists must end in a NORMAL exit 128+n (handler), never death by
# the signal (the shell's $? hides that difference, so a python driver reads the real returncode)
cat >"$S/early.py" <<'PYEOF'
import os, signal, subprocess, sys, time

script, repo, ready, sig, want, wt = sys.argv[1:7]
env = dict(os.environ, TRAIN_SELFTEST="1", TRAIN_TEST_PAUSE_AFTER_HANDLERS="0.5", TRAIN_TEST_READY_FILE=ready)
p = subprocess.Popen([sys.executable, "-I", "-B", script, "--base", "main", "--repo", repo, "--verify", "true",
                      "--log-dir", os.path.join(os.path.dirname(ready), "logs"), "n1", "n2"], cwd=wt,
                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, env=env)
for _ in range(100):
    if os.path.exists(ready):
        break
    time.sleep(0.05)
else:
    p.kill()
    print("no ready file")
    sys.exit(0)
p.send_signal(getattr(signal, "SIG" + sig))
try:
    rc = p.wait(timeout=20)
except subprocess.TimeoutExpired:
    p.kill()
    rc = "hang"
print("ok" if rc == int(want) else "rc %s, wanted a normal exit %s" % (rc, want))
PYEOF
for sg in HUP TERM INT; do
    case $sg in HUP) want=129 ;; TERM) want=143 ;; INT) want=130 ;; esac
    rm -f "$S/ready"
    quarantine
    ident_begin "$NC"
    check "early $sg: a normal exit $want (handler installed before the ready file)" eq "$(python3 -I -B "$S/early.py" "$SCRIPT" "$NC" "$S/ready" "$sg" "$want" "$WT")" ok
    check "early $sg: no itrain-* created" eq "$(ls "$S/tmp" | wc -l | tr -d ' ')" 0
    BR=
    ident_end "early $sg" "$NC"
done

# (f2) a signal INSIDE Popen/just after it, deterministic: the tool pauses right after it started its first
# WRITING git child (`git init`; the hook makes that child write into the private root 0.8 s later, as a
# slow git child does after an early cleanup) and before the child
# is registered; the signal must end in exit 128+n, kill that child, and leave no itrain-* (settled 1.3 s).
cat >"$S/hold.py" <<'PYEOF'
import os, signal, subprocess, sys, time

script, repo, hold, sig, tmpdir, wt = sys.argv[1:7]
env = dict(os.environ, TRAIN_SELFTEST="1", TRAIN_TEST_HOLD_FILE=hold, TMPDIR=tmpdir)
p = subprocess.Popen([sys.executable, "-I", "-B", script, "--base", "main", "--repo", repo, "--verify", "true",
                      "--log-dir", os.path.join(os.path.dirname(hold), "logs"), "n1", "n2"], cwd=wt,
                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, env=env)
for _ in range(400):
    if os.path.exists(hold):
        break
    time.sleep(0.025)
else:
    p.kill()
    print("no hold file")
    sys.exit(0)
p.send_signal(getattr(signal, "SIG" + sig))
try:
    rc = p.wait(timeout=20)
except subprocess.TimeoutExpired:
    p.kill()
    rc = "hang"
time.sleep(1.3)
print("rc=%s left=%d" % (rc, len([x for x in os.listdir(tmpdir) if x.startswith("itrain-")])))
PYEOF
for sg in HUP TERM; do
    case $sg in HUP) want=129 ;; TERM) want=143 ;; esac
    rm -f "$S/hold"
    mkdir -p "$S/holdtmp"
    ident_begin "$NC"
    check "signal $sg inside spawn: exit $want and no itrain-* left once the delayed child would have written" eq "$(python3 -I -B "$S/hold.py" "$SCRIPT" "$NC" "$S/hold" "$sg" "$S/holdtmp" "$WT")" "rc=$want left=0"
    rm -rf -- "$S"/holdtmp/itrain-*
    BR=
    ident_end "signal $sg inside spawn" "$NC"
done

# (g) item 0: a member red ALONE is retried once against the final landed set
V_FIX='if grep -rq POISON . ; then echo FAIL poison; exit 1; fi; if [ -f n1.txt ] && [ ! -f n3.txt ]; then echo FAIL n1 needs n3; exit 1; fi; echo ok'
ident_begin "$NC"
REPOARG=$NC V="$V_FIX" trn --keep n1 po n3
check "item 0 (fixed by a later member): n1 lands in recovery with n3" has "$JSON" '"landed":["n1","n3"]'
check "item 0: the fixer's victim is no longer ejected" lacks "$JSON" '"id":"n1"'
check "item 0: the poison stays out red, red_with the landed set, still red alone" has "$JSON" '"red_with":["n1","n3"]'
check "item 0: verified_red_alone on the poison record" has "$JSON" '"verified_red_alone":true'
check "item 0: runs as counted (6: all, [n1,po], [n1], [po], [n3], [n1,n3]; the retry of po runs [n1,po,n3] = run 1, cached)" has "$JSON" '"runs":6,'
ident_end "item 0 fixed" "$NC"
ident_begin "$NC"
REPOARG=$NC V="$V_FIX" trn --keep n1 n2
check "item 0 (stays red): n2 lands, n1 stays ejected" has "$JSON" '"landed":["n2"]'
check "item 0 (stays red): n1 carries red_with [n2] and verified_red_alone" eq "$(has "$JSON" '"id":"n1","why":"red"' && has "$JSON" '"red_with":["n2"]' && has "$JSON" '"verified_red_alone":true' && echo y)" y
ident_end "item 0 red" "$NC"
REPOARG=$NC V="$V_FIX" trn --no-recover --keep n1 n2
check "item 0: --no-recover leaves the red-alone member exactly as measured (no red_with, no retry)" eq "$(lacks "$JSON" red_with && lacks "$JSON" verified_red_alone && has "$JSON" '"runs":3,' && echo y)" y
[ -n "$BR" ] && "$REAL_GIT" -C "$NC" branch -D "$BR" >/dev/null 2>&1

# (h) delivery is all-or-nothing AS OBSERVED, for a signal at any instant: at exit either the ref does not
# exist and nothing names it, or it exists and the branch line and the JSON name it. Deterministic cases: a
# test hook (TRAIN_SELFTEST only) pauses right after update-ref was spawned, before it is waited for; "complete"
# lets it finish inside the pause, "kill" delays its start so a tool that kills it would leave no ref.
cat >"$S/deliv.py" <<'PYEOF'
import json, os, random, shutil, signal, subprocess, sys, time

G = os.environ["REAL_GIT"]
mode = sys.argv[1]
script, caller, ready, tmpdir, wt = sys.argv[2:7]
names = {"TERM": 143, "INT": 130, "HUP": 129}


def refs():
    return subprocess.run([G, "-C", caller, "for-each-ref", "--format=%(refname:short) %(objectname)",
                           "refs/heads/train-*"], capture_output=True, text=True).stdout.split("\n")[:-1]


def tool(extra_env, sig, delay, anchor=None):
    """One delivery run with a signal `delay` s after the anchor file (the start of delivery, or the
    end of index-pack); returns the observation."""
    for f in (ready, ready + ".indexed"):
        if os.path.exists(f):
            os.unlink(f)
    mark = anchor or ready
    env = dict(os.environ, TRAIN_SELFTEST="1", TMPDIR=tmpdir, **extra_env)
    p = subprocess.Popen([sys.executable, "-I", "-B", script, "--base", "main", "--repo", caller, "--verify", "true",
                          "--keep", "--log-dir", os.path.join(os.path.dirname(ready), "logs"), "n1"], cwd=wt,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, stdin=subprocess.DEVNULL, env=env)
    if sig:
        for _ in range(4000):
            if os.path.exists(mark) or p.poll() is not None:
                break
            time.sleep(0.0005)
        time.sleep(delay)
        if p.poll() is None:
            p.send_signal(getattr(signal, "SIG" + sig))
    out, err = p.communicate(timeout=60)
    rs = refs()
    out = out.decode("utf-8", "replace")
    lines = [x for x in out.split("\n") if x.startswith("integration branch: ")]
    try:
        js = json.loads(out.strip().split("\n")[-1])
    except ValueError:
        js = {}
    named = js.get("branch", "")
    for r in rs:
        subprocess.run([G, "-C", caller, "update-ref", "-d", "refs/heads/" + r.split()[0]], check=True)
    for x in os.listdir(tmpdir):
        if x.startswith("itrain-"):
            shutil.rmtree(os.path.join(tmpdir, x), ignore_errors=True)
    return {"rc": p.returncode, "ref": len(rs), "line": len(lines),
            "json": int(bool(named) and named in [r.split()[0] for r in rs]),
            "same": int(bool(rs) and rs[0].split()[1] == js.get("commits", {}).get("n1")),
            "flag": int(js.get("interrupted_after_delivery") is True),
            "derr": int("does not exist" in js.get("delivery_error", ""))}


def fmt(o, keys):
    return " ".join("%s=%s" % (k, o[k]) for k in keys)


if mode == "case":  # a hook pauses right after update-ref was spawned; the signal arrives in the pause
    hook, sg, tmo = sys.argv[7:10]
    extra = {"TRAIN_TEST_UPDATEREF": hook, "TRAIN_TEST_UPDATEREF_READY": ready}
    if tmo != "-":
        extra["TRAIN_TEST_UPDATEREF_TIMEOUT"] = tmo
    o = tool(extra, None if sg == "none" else sg, 0)
    print(fmt(o, ["rc", "ref", "line", "json", "same", "flag"] if sg != "none" else ["rc", "ref", "line", "json", "derr"]))
elif mode == "early":  # a signal 0-30 ms after spawn, maybe inside CPython's own start-up
    n, seed = int(sys.argv[7]), int(sys.argv[8])
    rng = random.Random(seed)
    verdicts = nojson = bad = 0
    for i in range(n):
        p = subprocess.Popen([sys.executable, "-I", "-B", script, "--base", "main", "--repo", caller, "--verify", "true",
                              "--log-dir", os.path.join(os.path.dirname(ready), "logs"), "n1"], cwd=wt,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, stdin=subprocess.DEVNULL,
                             env=dict(os.environ, TMPDIR=tmpdir))
        time.sleep(0 if i == 0 else rng.uniform(0, 0.03))
        if p.poll() is None:
            p.send_signal(signal.SIGINT)
        out = p.communicate(timeout=60)[0].decode("utf-8", "replace")
        if p.returncode in (0, 1):
            verdicts += 1
            try:
                json.loads(out.strip().split("\n")[-1])
            except ValueError:
                nojson += 1  # exit 0/1 with no JSON: NOT a verdict (CPython start-up) ...
                bad += int(bool(out.strip()))  # ... and then stdout must be EMPTY, never a partial report
        for x in os.listdir(tmpdir):
            if x.startswith("itrain-"):
                shutil.rmtree(os.path.join(tmpdir, x), ignore_errors=True)
    print("runs=%d exit-0/1=%d of-which-without-json=%d without-json-but-with-output=%d" % (n, verdicts, nojson, bad))
else:  # the sweep: signals at random instants from the start of delivery
    n, seed, span = int(sys.argv[7]), int(sys.argv[8]), float(sys.argv[9])
    rng = random.Random(seed)
    both = none = viol = 0
    rcs = {}
    for i in range(n):
        sg = ("TERM", "INT", "HUP")[i % 3]
        # half of the runs land in the 6 ms after index-pack ends (where update-ref starts), half anywhere
        # from the start of delivery, so the sweep is shown to hit BOTH outcomes
        o = tool({"TRAIN_TEST_DELIVERY_READY": ready, "TRAIN_TEST_INDEXED_READY": ready + ".indexed"}, sg,
                 rng.uniform(0, 0.006) if i % 2 == 0 else rng.uniform(0, span),
                 ready + ".indexed" if i % 2 == 0 else None)
        rcs[o["rc"]] = rcs.get(o["rc"], 0) + 1
        if o["ref"] == 1 and o["line"] == 1 and o["json"] == 1:
            both += 1
        elif o["ref"] == 0 and o["line"] == 0 and o["json"] == 0:
            none += 1
        else:
            viol += 1
            sys.stderr.write("violation %d: %s\n" % (i, o))
    print("runs=%d ref+line+json=%d no-ref+no-line+no-json=%d violations=%d" % (n, both, none, viol))
PYEOF
mkdir -p "$S/delivtmp"
ident_begin "$NC"
for sg in TERM INT HUP; do
    case $sg in HUP) want=129 ;; INT) want=130 ;; TERM) want=143 ;; esac
    for hk in complete kill; do
        check "delivery: $sg while update-ref is in flight ($hk): exit $want, the branch exists, is named by the line and the JSON, equals the verified commit, says interrupted" eq "$(python3 -I -B "$S/deliv.py" case "$SCRIPT" "$NC" "$S/dready" "$S/delivtmp" "$WT" "$hk" "$sg" -)" "rc=$want ref=1 line=1 json=1 same=1 flag=1"
    done
done
check "delivery: an update-ref that outlives its hard timeout is exit 2, the ref is read back (absent), the JSON says so" eq "$(python3 -I -B "$S/deliv.py" case "$SCRIPT" "$NC" "$S/dready" "$S/delivtmp" "$WT" kill none 0.3)" "rc=2 ref=0 line=0 json=0 derr=1"
SWEEP_OUT=$(python3 -I -B "$S/deliv.py" sweep "$SCRIPT" "$NC" "$S/dready" "$S/delivtmp" "$WT" 60 7 0.06 2>&1)
check "delivery sweep: 60 signals, none leaves a ref without its line and JSON, or a line without a ref ($SWEEP_OUT)" has "$SWEEP_OUT" "violations=0"
check "delivery sweep: both outcomes were hit (a ref delivered, and no ref at all)" eq "$(case $SWEEP_OUT in *"ref+line+json=0 "* | *"no-json=0 "*) echo one-sided ;; *) echo both ;; esac)" both
ident_end "delivery signals (objects may differ)" "$NC" objects
# the contract that makes a verdict checkable: exit 0/1 prints the JSON as the LAST stdout line; an early-killed run
# (CPython start-up, before the script's first line) has exit 1 or -2 and empty stdout: NOT a verdict
EARLY_OUT=$(python3 -I -B "$S/deliv.py" early "$SCRIPT" "$NC" "$S/dready" "$S/delivtmp" "$WT" 12 3 2>&1)
check "start-up: an early SIGINT never yields exit 0/1 with output but no JSON line; exit 0/1 without JSON has EMPTY stdout ($EARLY_OUT)" has "$EARLY_OUT" "without-json-but-with-output=0"
REPOARG=$NC trn n1
check "verdict contract: exit 0 prints the JSON as the last stdout line" eq "$RC$(printf '%s' "$OUT" | tail -n 1 | python3 -I -B -c 'import json,sys; json.loads(sys.stdin.read()); print("J")')" 0J
REPOARG=$NC V="exit 1" trn n1
check "verdict contract: exit 1 prints the JSON as the last stdout line" eq "$RC$(printf '%s' "$OUT" | tail -n 1 | python3 -I -B -c 'import json,sys; json.loads(sys.stdin.read()); print("J")')" 1J

# (i) the private repository's state channels a verify could use to carry a result from one run to the next.
# Each verify below is RED the first time (it leaves a mark in the shared private git directory, which it reaches
# by climbing two levels from its worktree) and GREEN when it finds the mark: without detection a later red run lands.
PRIV_P='P=$(cd ../.. && pwd)/repo.git'
V_SNAP_PACK="$PRIV_P"'; [ -f $P/objects/pack/mark ] && exit 0; : >$P/objects/pack/mark; exit 1'
V_SNAP_WT="$PRIV_P"'; [ -f $P/worktrees/mark/x ] && exit 0; mkdir -p $P/worktrees/mark && : >$P/worktrees/mark/x; exit 1'
V_SNAP_HEAD="$PRIV_P"'; [ "$(cat $P/HEAD)" = "ref: refs/heads/mark" ] && exit 0; echo "ref: refs/heads/mark" >$P/HEAD; exit 1'
V_SNAP_OBJ="$PRIV_P"'; H=$(echo state | git hash-object --stdin); git --git-dir=$P cat-file -e $H 2>/dev/null && exit 0; echo state | git --git-dir=$P hash-object -w --stdin >/dev/null; exit 1'
V_SNAP_CTL='git status >/dev/null; git diff --stat HEAD >/dev/null; echo x >new.txt; git add -A; git write-tree >/dev/null; git stash create >/dev/null 2>&1; exit 0'
for ch in "pack:objects/pack:$V_SNAP_PACK" "worktrees:worktrees:$V_SNAP_WT" "HEAD content:top-level:$V_SNAP_HEAD"; do
    nm=${ch%%:*}; rest=${ch#*:}; want=${rest%%:*}; vs=${rest#*:}
    REPOARG=$NC V="$vs" trn n1 n2
    check "snapshot channel ($nm): the run is void, exit 2 naming '$want'" eq "$RC$(has "$OUT" "verify changed the private repository: $want" && echo y)" "2y"
done
REPOARG=$NC V="$V_SNAP_OBJ" trn n1 n2
check "snapshot channel (loose object): documented as NOT digested; the run is not voided" eq "$RC$(has "$OUT" "verify changed the private repository" && echo y)" "1"
REPOARG=$NC V="$V_SNAP_CTL" trn n1 n2
check "snapshot control: git status/add/write-tree/stash create in the worktree void nothing, both land" eq "$RC$(has "$JSON" '"landed":["n1","n2"]' && echo y)" "0y"
fi # newc

# A skipped block replaces several checks on hosts where it cannot run (case-folding or
# Unicode-normalising filesystem, sha256 git, root user, no chflags): the ok count therefore
# differs by host, and every skip is named above and counted here.
echo "integration-train selftest: $PASS ok, $FAIL failed, $SKIP skipped, $((SECONDS - T0)) s"
[ "$FAIL" -eq 0 ]
