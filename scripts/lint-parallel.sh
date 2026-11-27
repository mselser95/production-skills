#!/usr/bin/env bash
# lint-parallel.sh -- shellcheck over every tracked *.sh: one file per call, in parallel,
# byte-identical copies linted once. It remembers nothing between runs.
#
# WHAT IT DOES. `git ls-files -z '*.sh'` (tracked files only: the set CI sees; a file is
# covered the moment it is staged), working-tree content. Each distinct file is linted
# alone with `shellcheck -x -S <sev> -- <path>` from the repo root, LINT_JOBS at a time.
# Output is in path order for any job count; findings are printed under the first path of
# a group, the other paths of the group are listed after them.
#
# WHY NO CACHE. An earlier version cached clean verdicts. A sound cache may reuse a
# verdict only if it depends on nothing but the file's own bytes and rc chain, which
# covers only the files that provably source nothing: a small minority of the groups. So
# a warm run cost about as much as a cold one, and the cache failed review twice. What
# remains is correct because it remembers nothing.
#
# DEDUPLICATION, one shared verdict, switched on or off for the WHOLE run. Two paths in
# the same run share ONE shellcheck run when their content sha256 and their rc chain are
# equal. Premise, measured on version 0.11.0 and kept as a selftest case: with -x from
# the repo root a relative source resolves against the working directory, so two identical
# copies in two directories follow the same file and get the same verdict, whatever sits
# next to each copy. The directory-relative source-path keyword breaks that premise (each
# copy then follows the file beside it), and it can sit in the file, in a file it
# sources, in an rc file named by $SHELLCHECK_OPTS, anywhere. So sharing is OFF, every
# path linted separately, when ANY of: the keyword occurs in any file of the work tree
# (`git grep -I --untracked`: tracked and untracked-not-ignored), in an rc file shellcheck
# could read (the chain, the rc files above the repo root, the user-level ones), or in
# $SHELLCHECK_OPTS; $SHELLCHECK_OPTS carries --rcfile, -P or --source-path (any value,
# not parsed); or the scan itself fails (fail closed). One line on stderr says why. This
# file and its selftest never contain the keyword contiguously (it is built at run time),
# so the tool's own source does not switch its optimisation off; a selftest case pins it.
#
# RC CHAIN (measured): the linter looks for a regular file named .shellcheckrc OR
# the name shellcheckrc in the file's directory and every parent up to /, and stops at the first
# directory that has one (a nearer rc replaces a farther one, even an empty one). A
# directory or dangling symlink of that name is skipped. Two paths share a run only if
# the rc files found, by path and content, are the same; the user-level rc files
# ($HOME/.shellcheckrc, $XDG_CONFIG_HOME/shellcheckrc, the "shellcheck" subdirectory
# variant) are part of that.
#
# -x PER FILE is the semantics. Without -x shellcheck follows a sourced file only when it
# is on the same command line; with -x it always does, so a verdict never depends on who
# shares the line.
#
# LOOSER THAN THE OLD SINGLE-CALL RECIPE in two cases (found by review, fixtures 05/06):
# a script sourcing a TRACKED NON-.sh file, or an UNTRACKED file. The old recipe could not
# see that file and reported SC2154 (a false positive: the variable is defined there);
# this one follows the source and is clean. Consequence: an untracked or out-of-tree
# sourced file can make the local verdict differ from CI's, which has only the clone.
#
# COST. One shellcheck per distinct (content, rc chain) group, so the invocation count
# is the cost driver (see the Makefile comment for the count and CPU seconds measured on
# the repo); the largest file dominates and is the floor. With -x the cost of a file grows
# faster than linearly in what it sources.
#
# TIMEOUT. A shellcheck that runs longer than LINT_FILE_TIMEOUT seconds (default 60) is
# killed and the run exits 2 with `timeout: <path>`: a tool error, never a pass and never
# a finding. A watchdog in the worker does it (no GNU timeout: not on stock macOS).
#
# Usage: lint-parallel.sh   (from anywhere inside the work tree)
#   LINT_JOBS          parallel shellcheck processes: default min(4, cores), and no more
#                      than a cgroup v2 CPU quota.
#   LINT_SEVERITY      default warning (the -S argument).
#   LINT_FILE_TIMEOUT  seconds per shellcheck, default 60.
# Exit: 0 every unique script clean; 1 findings; 2 tool or usage error (shellcheck
# missing, zero files, unreadable input, a path with a newline or tab, shellcheck exit
# >= 2 or killed, a timeout). 2 wins over 1. INT and TERM kill the workers' process
# group, remove the temp dir and exit 130 / 143; SIGKILL cannot be handled and can leave a
# $TMPDIR/lint-parallel.* dir.
set -uo pipefail

sev=${LINT_SEVERITY:-warning}
command -v shellcheck >/dev/null || { echo "shellcheck missing -- brew install shellcheck" >&2; exit 2; } # MUT:missing
root=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "lint: not inside a git work tree" >&2; exit 2; }
case $root in *$'\n'* | *$'\t'*) echo "lint: a repo path with a newline or tab is unsupported" >&2; exit 2 ;; esac
cd "$root" || exit 2

case ${LINT_JOBS:-1} in *[!0-9]*) echo "lint: LINT_JOBS must be an integer" >&2; exit 2 ;; esac
[ "${LINT_JOBS:-1}" -ge 1 ] || { echo "lint: LINT_JOBS must be >= 1" >&2; exit 2; }
TMO=${LINT_FILE_TIMEOUT:-60}
case $TMO in '' | *[!0-9]*) echo "lint: LINT_FILE_TIMEOUT must be an integer" >&2; exit 2 ;; esac
[ "$TMO" -ge 1 ] || { echo "lint: LINT_FILE_TIMEOUT must be >= 1" >&2; exit 2; }
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

if command -v shasum >/dev/null; then SHA=(shasum -a 256)
elif command -v sha256sum >/dev/null; then SHA=(sha256sum)
else echo "lint: neither shasum nor sha256sum found" >&2; exit 2; fi

T=$(mktemp -d "${TMPDIR:-/tmp}/lint-parallel.XXXXXX") || exit 2
cleanup() { case $T in */lint-parallel.*) rm -rf -- "$T" ;; esac; }
trap cleanup EXIT
xpid=""
on_sig() { # kill the workers' process group, then the EXIT trap removes the temp dir
  trap '' INT TERM
  [ -z "$xpid" ] || kill -TERM -- "-$xpid" 2> /dev/null # MUT:termkill
  [ -z "$xpid" ] || wait "$xpid" 2> /dev/null
  exit "$1"
}
trap 'on_sig 143' TERM
trap 'on_sig 130' INT
globals=("${HOME:-}/.shellcheckrc" "${XDG_CONFIG_HOME:-${HOME:-}/.config}/shellcheckrc" "${HOME:-}/.config/shellcheck/shellcheckrc") # MUT:userrc

# ---- input set: NUL-safe ---------------------------------------------------------------
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
if ! xargs -0 "${SHA[@]}" -- < "$T/files0" > "$T/hashes" 2> "$T/hash.err"; then
  echo "lint: cannot hash a tracked file (deleted from the tree?):" >&2; head -3 "$T/hash.err" >&2; exit 2
fi

# ---- rc chain per directory (shellcheck walks up to /, nearest wins) -----------------
LC_ALL=C awk '{ d = $0; if (!sub(/\/[^\/]*$/, "", d)) d = "."; if (!(d in s)) { s[d] = 1; print d } }' "$T/paths" > "$T/dirs"
{
  while IFS= read -r d; do
    if [ "$d" = . ]; then abs=$root; else abs=$root/$d; fi
    line="$d"
    while :; do
      c1=$abs/.shellcheckrc; c2=$abs/shellcheckrc; f1=""; f2=""
      [ ! -f "$c1" ] || f1=$c1
      [ ! -f "$c2" ] || f2=$c2
      if [ -n "$f1$f2" ]; then
        [ -z "$f1" ] || line="$line"$'\t'"$f1"
        [ -z "$f2" ] || line="$line"$'\t'"$f2"
        break
      fi
      [ -n "$abs" ] || break
      abs=${abs%/*}
    done
    printf '%s\n' "$line"
  done < "$T/dirs"
  line="@global"
  for g in "${globals[@]}"; do
    [ ! -f "$g" ] || line="$line"$'\t'"$g"
  done
  printf '%s\n' "$line"
} > "$T/dirrc"
awk -F'\t' '{ for (i = 2; i <= NF; i++) print $i }' "$T/dirrc" | LC_ALL=C sort -u > "$T/rclist"
: > "$T/rchash"
if [ -s "$T/rclist" ]; then
  if ! tr '\n' '\0' < "$T/rclist" | xargs -0 "${SHA[@]}" -- > "$T/rchash.raw" 2> "$T/hash.err"; then
    echo "lint: cannot read a .shellcheckrc:" >&2; head -3 "$T/hash.err" >&2; exit 2
  fi
  awk 'FILENAME == ARGV[1] { p[++n] = $0; next }
       { s = $0; if (substr(s, 1, 1) == "\\") s = substr(s, 2); print p[++m] "\t" substr(s, 1, 64) }' "$T/rclist" "$T/rchash.raw" > "$T/rchash"
fi

# ---- sharing switch: ONE global flag, decided before grouping ------------------------
# The keyword is built here so these bytes never carry it (see the header).
sd="SCRIPT""DIR"
off=""
case ${SHELLCHECK_OPTS:-} in *"$sd"*) off="$sd mentioned in SHELLCHECK_OPTS" ;; esac
case ${SHELLCHECK_OPTS:-} in *--rcfile*) off="SHELLCHECK_OPTS carries --rcfile" ;; esac # MUT:optsrcfile
case ${SHELLCHECK_OPTS:-} in *-P*) off="SHELLCHECK_OPTS carries -P" ;; esac # MUT:optsp
case ${SHELLCHECK_OPTS:-} in *--source-path*) off="SHELLCHECK_OPTS carries --source-path" ;; esac # MUT:optssp
if [ -z "$off" ]; then
  # every readable file of the work tree: git grep exit 0 match, 1 none, else a failure
  git grep -l -I --untracked -e "$sd" -- . > "$T/gg" 2> "$T/gg.err"; g=$? # MUT:scan
  [ "$g" -le 1 ] || off="git grep failed (exit $g); sharing nothing" # MUT:gitgrepfail
  [ "$g" -ne 0 ] || off="$sd mentioned in $(head -1 "$T/gg")"
fi
if [ -z "$off" ]; then
  # rc files outside git's view: every rc from the repo root up to /, the user-level ones,
  # and the in-tree chain (an ignored rc is invisible to git grep)
  {
    a=$root
    while :; do
      for rn in .shellcheckrc shellcheckrc; do [ ! -f "$a/$rn" ] || printf '%s\0' "$a/$rn"; done # MUT:undotted
      [ -n "$a" ] || break
      a=${a%/*} # MUT:abovewalk
    done
    for gf in "${globals[@]}"; do [ ! -f "$gf" ] || printf '%s\0' "$gf"; done
    awk -v r="$root/" 'index($0, r) == 1' "$T/rclist" | tr '\n' '\0'
  } > "$T/rcscan0"
  if [ -s "$T/rcscan0" ]; then # MUT:rcscan
    LC_ALL=C xargs -0 grep -a -l -e "$sd" -- < "$T/rcscan0" > "$T/rcgg" 2> "$T/rcgg.err" # exit 123 on no match is expected
    [ ! -s "$T/rcgg.err" ] || off="rc scan failed: $(head -1 "$T/rcgg.err"); sharing nothing"
    [ ! -s "$T/rcgg" ] || off="$sd mentioned in $(head -1 "$T/rcgg")"
  fi
fi
share=1
[ -z "$off" ] || { share=0; echo "dedupe: off -- $off" >&2; }

# ---- group by (content, rc chain); with sharing off every path is its own group ---------
# one line per group: representative (first path in byte order) TAB the other paths
ROOT="$root" SHARE=$share LC_ALL=C awk -F'\t' '
  function rel(p) { return index(p, ENVIRON["ROOT"] "/") == 1 ? substr(p, length(ENVIRON["ROOT"]) + 2) : p }
  function mat(line,   a, k, out, i) {
    k = split(line, a, "\t"); out = ""
    for (i = 2; i <= k; i++) out = out "rc=" rel(a[i]) ":" rh[a[i]] "\n"
    return out
  }
  FILENAME == ARGV[1] { split($0, a, "\t"); dm[a[1]] = $0; next }   # resolved in END: the rc hashes arrive next
  FILENAME == ARGV[2] { rh[$1] = $2; next }
  FILENAME == ARGV[3] { P[++np] = $0; next }
  { s = $0; if (substr(s, 1, 1) == "\\") s = substr(s, 2); H[++nh] = substr(s, 1, 64) }
  END {
    if (np != nh) { print "MISMATCH"; exit }
    for (i = 1; i <= np; i++) {
      p = P[i]; d = p; if (!sub(/\/[^\/]*$/, "", d)) d = "."
      k = H[i] # MUT:dedupe
      k = k "|" mat(dm["@global"]) "|" mat(dm[d]) # MUT:rcdedupe
      if (ENVIRON["SHARE"] != 1) k = k "|" p # MUT:sdirdedupe
      if (!(k in rep)) rep[k] = P[i]
      else if (P[i] < rep[k]) { oth[k] = oth[k] (oth[k] == "" ? "" : ", ") rep[k]; rep[k] = P[i] }
      else oth[k] = oth[k] (oth[k] == "" ? "" : ", ") P[i]
    }
    for (k in rep) print rep[k] "\t" oth[k]
  }' "$T/dirrc" "$T/rchash" "$T/paths" "$T/hashes" | LC_ALL=C sort > "$T/groups" # MUT:sortpipe
if grep -q '^MISMATCH' "$T/groups"; then echo "lint: could not pair the file list with its hashes" >&2; exit 2; fi
L=0; REP=(); OTH=()
: > "$T/lint.nul"
while IFS=$'\t' read -r rep others; do
  L=$((L + 1)); REP[L]=$rep; OTH[L]=$others
  printf '%s\0%s\0' "$L" "$rep" >> "$T/lint.nul"
done < "$T/groups"
if [ "$L" -eq 0 ]; then echo "lint: deduped to ZERO files -- refusing to report clean over nothing" >&2; exit 2; fi

# ---- lint: ONE file per shellcheck, with -x, in parallel -------------------------------
cat > "$T/worker.sh" <<'WORKER'
# $1 = index, $2 = path. Output and exit code go to files; never to the shared stdout.
# A watchdog kills the shellcheck after $TMO seconds and leaves the marker $T/to.$1.
shellcheck $X -S "$SEV" $DD "$2" > "$T/o.$1" 2>&1 &
sc=$!
( trap 'kill $(jobs -p) 2>/dev/null; exit 0' TERM; sleep "$TMO" & wait $!; kill -KILL "$sc" 2>/dev/null && : > "$T/to.$1" ) &
wd=$!
wait "$sc"; rc=$?
kill -TERM "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
[ ! -e "$T/to.$1" ] || rc=timeout # MUT:tomark
printf '%s\n' "$rc" > "$T/rc.$1"
WORKER
export T TMO
SEV=$sev; export SEV
X=-x; export X # MUT:noxflag
DD=--; export DD # MUT:dashdash
pick_jobs
# own process group (job control on for this one command): INT/TERM kill the group
set -m
xargs -0 -n 2 -P "$jobs" bash "$T/worker.sh" < "$T/lint.nul" &
xpid=$!
set +m
wait "$xpid"; xrc=$?
xpid=""
# the worker never exits non-zero: any non-zero here is the harness failing.
[ "$xrc" -eq 0 ] || { echo "lint: the parallel runner failed" >&2; exit 2; }

# ---- verdicts, in representative path order (so stdout is the same for any LINT_JOBS)
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
      [ -z "${OTH[i]}" ] || printf 'lint: the same verdict holds for %s\n' "${OTH[i]}"
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
if [ "$dirty" -gt 0 ]; then
  echo "shellcheck: findings in $dirty of $L unique script(s) at severity=$sev" >&2
  exit 1
fi
echo "shellcheck: $L unique script(s) of $n clean at severity=$sev"
