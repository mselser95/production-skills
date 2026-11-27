#!/usr/bin/env bash
# lint-parallel.sh -- shellcheck over every tracked *.sh: real files, one per call, in parallel.
# It remembers nothing between runs and shares nothing between files.
#
# WHAT IS LINTED (a definition, not an optimisation). THE CONTRACT IS OVER REAL FILES: for
# every tracked `*.sh` (`git ls-files -z '*.sh'`: the set CI sees; a file is covered the
# moment it is staged) take its real path (every symlink followed). Each distinct real file
# is linted exactly ONCE, by its repo-relative real path, with `shellcheck -x -S <sev> --
# <path>` from the repo root, working-tree content. A tracked symlink is not a separate
# script: it IS its target. The summary line says so: `N real file(s) linted for M tracked
# path(s); K symlink(s) resolve to a file already linted`. Findings are printed under the
# real path, followed by `also reachable as: <links>`.
#   - a tracked *.sh symlink whose target is outside the repo root, dangling, or a
#     directory: exit 2 naming it (the lint does not read outside the tree);
#   - a link to an in-repo file that is not tracked: the target is linted anyway and
#     `note: <link> -> <target> (target is not tracked)` goes to stderr; a clean run stays 0;
#   - a link whose target name does not end in .sh is still linted (it is reachable as a script).
#
# NO VERDICT IS SHARED between different real files, even byte-identical ones. An earlier
# version hashed contents and shared one verdict between equal copies; to do that soundly it
# had to predict everything shellcheck reads (rc files, source-path, ignored or binary
# sourced files, links out of the tree, abbreviated options) and four review rounds each
# found one more thing it could not see. shellcheck applies its rc files and options itself,
# so this tool no longer needs to know. Measured on this repo (2026-11-27): of 176 tracked
# *.sh, 25 are symlinks to another tracked script, and 22 invocations would have been saved
# by sharing between byte-identical REAL files (761 KB in all). Those files are linted
# separately on purpose, INCLUDING the second copy of the largest script (verify-standard.sh,
# 386 KB, about 3.7 s of CPU).
#
# A DEFINITION, NOT A PROOF OF EQUIVALENCE: a symlinked script that sources directory-
# relatively (source-path=SCRIPTDIR, dirname "$0") is checked only against its real
# directory's siblings; a link in another directory with different siblings is not checked.
# (shellcheck resolves that keyword from the path as given; measured on 0.11.0.)
#
# A link target is read exactly (readlink -n; a newline belonging to the name is kept). Exit 2,
# naming the link, when the link's own name, its target, or any intermediate LINK on the way
# contains a newline or a tab (a physically resolved path that is clean is linted), when the
# target is empty, or when the chain is longer than 40 links. Directories on the way are resolved physically (`d/..` after a symlinked `d`).
#
# -x PER FILE: shellcheck follows what a file sources, so a verdict never depends on who
# shares a command line. That is LOOSER than the old single-call recipe in two cases: a script
# sourcing a TRACKED NON-.sh file or an UNTRACKED file is followed and can be clean where the
# old recipe printed a false positive (SC2154). Consequence: an untracked or out-of-tree
# sourced file can make the local verdict differ from CI's, which has only the clone.
#
# COST. One shellcheck per real file: the invocation count is the cost driver (151 for 176
# tracked paths here); the largest file, verify-standard.sh, dominates and is the floor. CPU
# seconds of one run are in the Makefile comment (machine and load stated there). No
# wall-clock promise: it depends on load.
#
# TIMEOUT. A shellcheck that runs longer than LINT_FILE_TIMEOUT seconds (default 60) is
# signalled by a per-file watchdog (TERM, then KILL after 1 s; no GNU timeout: not on stock
# macOS) and the run exits 2 with `timeout: <path>`: a tool error, never a pass and never a
# finding. The watchdog records its firing in a marker file BEFORE it signals, and the exit
# is classified by that marker, so it is `timeout` every time and never `exit 137`. When
# the file finishes first, the watchdog and its sleep are signalled and reaped.
#
# Usage: lint-parallel.sh   (from anywhere inside the work tree)
#   LINT_JOBS          parallel shellcheck processes: default min(4, cores), and no more
#                      than a cgroup v2 CPU quota.
#   LINT_SEVERITY      default warning (the -S argument).
#   LINT_FILE_TIMEOUT  seconds per shellcheck, default 60.
# Exit: 0 every real file clean; 1 findings; 2 tool or usage error (shellcheck missing, zero
# files, unreadable input, a link out of the tree / dangling / to a directory, a path with a
# newline or tab, shellcheck exit >= 2 or killed, a timeout). 2 wins over 1. Output is in
# real-path order for any job count. INT, TERM and HUP send TERM to the workers' process
# group, wait at most 1 s, send KILL to what is left, remove the temp dir and exit 130 / 143 /
# 129. SIGKILL of this script cannot be handled: it orphans the workers and can leave a
# $TMPDIR/lint-parallel.* dir. A grandchild that creates its own session survives a signal.
# K in the summary counts links to a tracked file; links to an untracked file (linted only
# through the link) are counted and worded separately.
set -uo pipefail

sev=${LINT_SEVERITY:-warning}
command -v shellcheck >/dev/null || { echo "shellcheck missing -- brew install shellcheck" >&2; exit 2; } # MUT:missing
root=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "lint: not inside a git work tree" >&2; exit 2; }
case $root in *$'\n'* | *$'\t'*) echo "lint: a repo path with a newline or tab is unsupported" >&2; exit 2 ;; esac
cd "$root" && root=$(pwd -P) && cd "$root" || exit 2

case ${LINT_JOBS:-1} in *[!0-9]*) echo "lint: LINT_JOBS must be an integer" >&2; exit 2 ;; esac
[ "${LINT_JOBS:-1}" -ge 1 ] || { echo "lint: LINT_JOBS must be >= 1" >&2; exit 2; }
TMO=${LINT_FILE_TIMEOUT:-60}
case $TMO in '' | *[!0-9]*) echo "lint: LINT_FILE_TIMEOUT must be an integer" >&2; exit 2 ;; esac
[ "$TMO" -ge 1 ] || { echo "lint: LINT_FILE_TIMEOUT must be >= 1" >&2; exit 2; }
GRACE=1 # seconds between TERM and KILL, for a signalled run and for a timed-out file
pick_jobs() { # LINT_JOBS, else min(4, cores) and no more than a cgroup CPU quota
  jobs=${LINT_JOBS:-}
  if [ -z "$jobs" ]; then
    jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null) || jobs=""
    case $jobs in '' | *[!0-9]*) jobs=$(sysctl -n hw.ncpu 2>/dev/null) || jobs="" ;; esac
    case $jobs in '' | *[!0-9]* | 0) jobs=2 ;; esac
    [ "$jobs" -le 4 ] || jobs=4
    # a container's CPU quota (cgroup v2) is invisible to getconf (measured: oversubscribing it is slower)
    if [ -r /sys/fs/cgroup/cpu.max ] && read -r quota period < /sys/fs/cgroup/cpu.max; then
      case $quota$period in
        *[!0-9]*) ;;
        *) quota=$(((quota + period - 1) / period)); [ "$quota" -lt 1 ] || [ "$jobs" -le "$quota" ] || jobs=$quota ;;
      esac
    fi
  fi
}

T=$(mktemp -d "${TMPDIR:-/tmp}/lint-parallel.XXXXXX") || exit 2
cleanup() { case $T in */lint-parallel.*) rm -rf -- "$T" ;; esac; }
trap cleanup EXIT
xpid=""
on_sig() { # TERM the workers' process group, bounded grace, KILL it; the EXIT trap removes the temp dir
  trap '' INT TERM HUP
  if [ -n "$xpid" ]; then
    kill -TERM -- "-$xpid" 2> /dev/null # MUT:termkill
    wait "$xpid" 2> /dev/null
    # a member that ignores TERM would outlive us: one bounded sleep, then KILL
    if kill -0 -- "-$xpid" 2> /dev/null; then sleep "$GRACE"; fi
    kill -KILL -- "-$xpid" 2> /dev/null # MUT:killesc
  fi
  exit "$1"
}
trap 'on_sig 143' TERM
trap 'on_sig 130' INT
trap 'on_sig 129' HUP

# ---- input set: tracked *.sh, NUL-safe, resolved to real files --------------------------
git ls-files -z '*.sh' > "$T/files0" || exit 2 # MUT:gitls
if ! [ -s "$T/files0" ]; then
  echo "lint: found ZERO shell scripts -- a clean lint over nothing is not a clean lint" >&2; exit 2 # MUT:zeroguard
fi
n=0
while IFS= read -r -d '' p; do
  case $p in *$'\n'* | *$'\t'*) echo "lint: a tracked *.sh path contains a newline or a tab -- unsupported, refusing" >&2; exit 2 ;; esac
  printf '%s\n' "$p"
  n=$((n + 1))
done < "$T/files0" > "$T/paths"

# resolve P -> REAL (absolute, every link followed, each directory made physical), or return 1 with RERR.
# A link target is read with readlink; the directory of every hop is made physical first, so `..` after
# a symlinked directory means what the kernel means.
resolve() {
  local p=$1 hops=0 d t
  while :; do
    d=${p%/*}; [ "$d" != "$p" ] || d=.; [ -n "$d" ] || d=/
    d=$(cd -P -- "$d" 2> /dev/null && pwd -P) || { RERR="a directory on its way is missing"; return 1; } # MUT:physical
    p=${d%/}/${p##*/}
    case $p in *$'\n'* | *$'\t'*) RERR="a path on its way contains a newline or a tab"; return 1 ;; esac # MUT:nlcheck
    [ -L "$p" ] || break
    hops=$((hops + 1)); [ "$hops" -le 40 ] || { RERR="too many levels of symbolic links"; return 1; } # MUT:hopcap
    # readlink -n prints the target with no newline of its own (the BSD and GNU ones differ without -n);
    # the printf x keeps $(...) from eating a newline that belongs to the name
    t=$(readlink -n -- "$p" && printf x) || { RERR="cannot read the link"; return 1; } # MUT:rlnl
    t=${t%x} # MUT:rlnl2
    [ -n "$t" ] || { RERR="target is empty"; return 1; }
    case $t in /*) p=$t ;; *) p=$d/$t ;; esac
  done
  [ -e "$p" ] || { RERR="dangling (target $p does not exist)"; return 1; } # MUT:dangling
  [ ! -d "$p" ] || { RERR="target $p is a directory"; return 1; } # MUT:isdir
  [ -f "$p" ] || { RERR="target $p is not a regular file"; return 1; } # MUT:notreg
  REAL=$p
}
nlinks=0; nuntr=0
: > "$T/map"
while IFS= read -r p; do
  if [ -L "$p" ]; then # MUT:realpath
    resolve "$p" || { echo "lint: tracked link $p: $RERR -- refusing (exit 2)" >&2; exit 2; }
    case $REAL in
      "$root"/*) rel=${REAL#"$root"/} ;; # MUT:outside
      *) echo "lint: tracked link $p -> $REAL points outside the repository -- refusing (exit 2)" >&2; exit 2 ;;
    esac
    if git ls-files --error-unmatch -- ":(literal)$rel" > /dev/null 2>&1; then nlinks=$((nlinks + 1))
    else nuntr=$((nuntr + 1)); echo "note: $p -> $rel (target is not tracked)" >&2; fi
  else
    [ -f "$p" ] && [ -r "$p" ] || { echo "lint: cannot read tracked file $p (deleted from the tree?)" >&2; exit 2; }
    rel=$p
  fi
  printf '%s\t%s\n' "$rel" "$p"
done < "$T/paths" > "$T/map"
# one line per real file: real path TAB the other tracked names (links), in byte order
LC_ALL=C sort -t "$(printf '\t')" -k1,1 -k2,2 "$T/map" > "$T/map.sorted" # MUT:sortmap
LC_ALL=C awk -F'\t' '
  function flush() { if (cur != "") print cur "\t" als }
  $1 != cur { flush(); cur = $1; als = "" }
  $2 != $1 { als = als (als == "" ? "" : ", ") $2 }
  END { flush() }' "$T/map.sorted" > "$T/groups"
L=0; REP=(); OTH=()
: > "$T/lint.nul"
while IFS=$'\t' read -r rep others; do
  L=$((L + 1)); REP[L]=$rep; OTH[L]=$others
  printf '%s\0%s\0' "$L" "$rep" >> "$T/lint.nul" # MUT:share
done < "$T/groups"
if [ "$L" -eq 0 ]; then echo "lint: resolved to ZERO files -- refusing to report clean over nothing" >&2; exit 2; fi

# ---- lint: ONE real file per shellcheck, with -x, in parallel --------------------------
cat > "$T/worker.sh" <<'WORKER'
# $1 = index, $2 = path. Output and exit code go to files; never to the shared stdout.
# The watchdog writes the marker $T/to.$1 BEFORE it signals, TERM then KILL after $GRACE; the marker,
# not the exit status, decides "timeout". When the file finishes first the watchdog is signalled and reaped.
# Each shellcheck runs in its OWN process group (job control for that one command), so a wrapper in front
# of it cannot leave children behind: the watchdog and an abort signal address the group.
sc=""; wd=""
trap '[ -z "$sc" ] || kill -KILL -- "-$sc" 2>/dev/null || kill -KILL "$sc" 2>/dev/null; [ -z "$wd" ] || kill -TERM "$wd" 2>/dev/null; exit 143' TERM HUP INT
set -m
shellcheck $X -S "$SEV" $DD "$2" > "$T/o.$1" 2>&1 &
sc=$!
set +m
(
  trap 'kill $(jobs -p) 2>/dev/null; wait; exit 0' TERM
  sleep "$TMO" & wait $!
  : > "$T/to.$1"
  kill -TERM -- "-$sc" 2>/dev/null || kill -TERM "$sc" 2>/dev/null # MUT:wdterm
  sleep "$GRACE" & wait $!
  kill -KILL -- "-$sc" 2>/dev/null || kill -KILL "$sc" 2>/dev/null # MUT:wdkill
  exit 0
) &
wd=$!
wait "$sc"; rc=$?
kill -TERM "$wd" 2>/dev/null # MUT:wdreap
wait "$wd" 2>/dev/null
[ ! -e "$T/to.$1" ] || rc=timeout # MUT:tomark
printf '%s\n' "$rc" > "$T/rc.$1"
WORKER
export T TMO GRACE
SEV=$sev; export SEV
X=-x; export X # MUT:noxflag
DD=--; export DD # MUT:dashdash
pick_jobs
# own process group (job control on for this one command): INT/TERM/HUP signal the group
set -m
xargs -0 -n 2 -P "$jobs" bash "$T/worker.sh" < "$T/lint.nul" &
xpid=$!
set +m
wait "$xpid"; xrc=$?
xpid=""
# the worker never exits non-zero: any non-zero here is the harness failing.
[ "$xrc" -eq 0 ] || { echo "lint: the parallel runner failed" >&2; exit 2; }

# ---- verdicts, in real-path order (so stdout is the same for any LINT_JOBS) --------------
dirty=0; toolerr=0
i=1
while [ "$i" -le "$L" ]; do
  rcv=""
  read -r rcv < "$T/rc.$i" 2> /dev/null || rcv=""
  case $rcv in
    0) # MUT:rc0
      ;;
    1) # MUT:rc1
      cat "$T/o.$i"
      [ -z "${OTH[i]}" ] || printf 'also reachable as: %s\n' "${OTH[i]}" # MUT:alsoprint
      dirty=$((dirty + 1))
      ;;
    timeout)
      toolerr=$((toolerr + 1))
      echo "lint: timeout: ${REP[i]} (no verdict within ${TMO}s; LINT_FILE_TIMEOUT raises it) -- not a finding" >&2
      ;;
    *)
      toolerr=$((toolerr + 1))
      echo "lint: TOOL ERROR on ${REP[i]}: shellcheck exit '${rcv:-none}' (not a finding): $(head -1 "$T/o.$i" 2> /dev/null)" >&2
      head -c 400 "$T/o.$i" 2> /dev/null >&2
      ;;
  esac
  i=$((i + 1))
done

if [ "$toolerr" -gt 0 ]; then
  echo "lint: $toolerr tool error(s): the lint did not complete -- exit 2" >&2
  exit 2
fi
extra=""
[ "$nuntr" -eq 0 ] || extra="; $nuntr symlink(s) lead to an untracked file, linted only through the link"
echo "shellcheck: $L real file(s) linted for $n tracked path(s); $nlinks symlink(s) resolve to a file already linted$extra; severity=$sev"
if [ "$dirty" -gt 0 ]; then
  echo "shellcheck: findings in $dirty of $L real file(s)" >&2
  exit 1
fi
