#!/usr/bin/env bash
# integration-train-selftest.sh -- hermetic proof of scripts/integration-train.py.
#
# One scratch BARE repo (built by one `git fast-import`), a linked worktree of it
# as "the caller's tree" (made dirty on purpose), a fake verify script. No
# network, no Docker. Every case asserts the summary JSON AND the git state:
# integration branch content, commit count, and the caller's tree untouched.
#
# Set TRAIN_SCRIPT to point at a mutated copy (mutation proofs do exactly that).
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
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
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
    fi_commit main "base moves" "" "conf.txt=$(printf 'l1\nBASE2\nl3')"
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
#!/bin/sh
echo "$1 $(pwd -P)" >>"$GITLOG"
case "$1" in
push|reset|clean|stash|checkout) echo "forbidden git $1" >&2; exit 97 ;;
cherry-pick|merge|commit)
    root=$(cd "$TMPDIR" && pwd -P)
    case $(pwd -P) in
    "$root"/itrain-*) ;;
    *) echo "git $1 outside a temp worktree: $(pwd -P)" >&2; exit 97 ;;
    esac ;;
esac
exec "$REAL_GIT" "$@"
EOF
chmod +x "$S/fakegit"
mkdir -p "$S/failbin" "$S/oldbin"
cat >"$S/failbin/git" <<'EOF'
#!/bin/sh
case "$1" in
merge-tree|cherry-pick|merge) echo "error: unknown option merge-base" >&2
    echo "usage: git $1 [options]" >&2; exit 129 ;;
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
    (cd "$WT" && PATH=$p exec python3 -I -B "$SCRIPT" --base "${BASE:-main}" --verify "${V:-$VERIFY}" \
        --log-dir "$S/logs" "$@") >"$S/out.txt" 2>&1 &
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
trn g1 g2 g3 x4
check "poison@4: 4 runs" has "$JSON" '"runs":4,'
check "poison@4: x4 ejected inferred" has "$JSON" '"inferred":true'
check "poison@4: landed 3" has "$JSON" '"landed":["g1","g2","g3"]'
finish "poison@4"

# ---- two poisoned / all poisoned ----------------------------------------
begin
trn --keep x1 g2 g3 x4
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
trn --keep fa g2 fb g4
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

echo "integration-train selftest: $PASS passed, $FAIL failed, $((SECONDS - T0)) s"
[ "$FAIL" -eq 0 ]
