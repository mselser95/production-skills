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
# WHY NO CACHE. An earlier version cached clean verdicts. With a sound rule (a verdict may
# be reused only if it depends on nothing but the file's own bytes and rc chain) 118 of
# the repo's 129 distinct groups could not be cached, so the cache saved 11 files and a
# warm run cost as much as a cold one. It was also the part that failed review twice.
# What remains is correct because it remembers nothing.
#
# DEDUPLICATION, the one shared verdict. Two paths in the SAME run share ONE shellcheck
# run when their content sha256 and their rc chain are equal. The premise, measured on
# version 0.11.0 and kept as a selftest case: with -x from the repo root a relative
# source resolves against the working directory, so two identical copies in two
# directories follow the same file and get the same verdict, whatever sits next to each
# copy; with `source-path=SCRIPTDIR` each copy follows the file beside it. So a path
# whose bytes, rc files or $SHELLCHECK_OPTS contain SCRIPTDIR is never shared.
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
# shares the line. The selftest shows a sourcing file failing on a sourced array (the old
# one-call recipe fails it too) and a sourced file's change flipping the verdict on the
# next run; that is all it proves about equality with the old recipe.
#
# COST (measured, shellcheck 0.11.0, loaded laptop): 176 tracked files, 129 distinct
# groups, so 129 invocations on every run: 8.5 to 9.2 s at 4 jobs. The slowest file is
# verify-standard.sh at about 5 s; that is the floor.
#
# Usage: lint-parallel.sh   (from anywhere inside the work tree)
#   LINT_JOBS       parallel shellcheck processes: default min(4, cores), and no more
#                   than a cgroup v2 CPU quota.
#   LINT_SEVERITY   default warning (the -S argument).
# Exit: 0 every unique script clean; 1 findings; 2 tool or usage error (shellcheck
# missing, zero files, unreadable input, a path with a newline or tab, shellcheck exit
# >= 2 or killed). 2 wins over 1. The temp dir is removed on EXIT and TERM; SIGKILL
# cannot be handled and can leave a $TMPDIR/lint-parallel.* dir.
set -uo pipefail

sev=${LINT_SEVERITY:-warning}
command -v shellcheck >/dev/null || { echo "shellcheck missing -- brew install shellcheck" >&2; exit 2; } # MUT:missing
root=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "lint: not inside a git work tree" >&2; exit 2; }
case $root in *$'\n'* | *$'\t'*) echo "lint: a repo path with a newline or tab is unsupported" >&2; exit 2 ;; esac
cd "$root" || exit 2

case ${LINT_JOBS:-1} in *[!0-9]*) echo "lint: LINT_JOBS must be an integer" >&2; exit 2 ;; esac
[ "${LINT_JOBS:-1}" -ge 1 ] || { echo "lint: LINT_JOBS must be >= 1" >&2; exit 2; }
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
trap 'exit 143' TERM

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
  for g in "${HOME:-}/.shellcheckrc" "${XDG_CONFIG_HOME:-${HOME:-}/.config}/shellcheckrc" "${HOME:-}/.config/shellcheck/shellcheckrc"; do
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

# ---- SCRIPTDIR: bytes or rc files (or the opts) that mention it are never shared --------
# grep exit 1 (no match) makes xargs exit 123, so a real failure is told apart by grep's stderr.
: > "$T/grep.err"
LC_ALL=C xargs -0 grep -a -l --null -e SCRIPTDIR -- < "$T/files0" 2>> "$T/grep.err" | tr '\0' '\n' > "$T/sdir"
: > "$T/rcsd"
if [ -s "$T/rclist" ]; then
  tr '\n' '\0' < "$T/rclist" | LC_ALL=C xargs -0 grep -a -l --null -e SCRIPTDIR -- 2>> "$T/grep.err" | tr '\0' '\n' > "$T/rcsd"
fi
[ ! -s "$T/grep.err" ] || { echo "lint: could not scan the files:" >&2; head -3 "$T/grep.err" >&2; exit 2; }
optssd=0
case ${SHELLCHECK_OPTS:-} in *SCRIPTDIR*) optssd=1 ;; esac

# ---- group by (content, rc chain); a SCRIPTDIR path is its own group -------------------
# one line per group: representative (first path in byte order) TAB the other paths
ROOT="$root" OPTSSD=$optssd LC_ALL=C awk -F'\t' '
  function rel(p) { return index(p, ENVIRON["ROOT"] "/") == 1 ? substr(p, length(ENVIRON["ROOT"]) + 2) : p }
  function mat(line,   a, k, out, i) {
    k = split(line, a, "\t"); out = ""
    for (i = 2; i <= k; i++) out = out "rc=" rel(a[i]) ":" rh[a[i]] "\n"
    return out
  }
  function rcsdir(line,   a, k, i) {
    k = split(line, a, "\t")
    for (i = 2; i <= k; i++) if (a[i] in rcs) return 1
    return 0
  }
  FILENAME == ARGV[1] { split($0, a, "\t"); dm[a[1]] = $0; next }   # resolved in END: the rc hashes arrive next
  FILENAME == ARGV[2] { rh[$1] = $2; next }
  FILENAME == ARGV[3] { sf[$0] = 1; next }
  FILENAME == ARGV[4] { rcs[$0] = 1; next }
  FILENAME == ARGV[5] { P[++np] = $0; next }
  { s = $0; if (substr(s, 1, 1) == "\\") s = substr(s, 2); H[++nh] = substr(s, 1, 64) }
  END {
    if (np != nh) { print "MISMATCH"; exit }
    gs = (ENVIRON["OPTSSD"] == 1 || rcsdir(dm["@global"])) ? 1 : 0
    for (i = 1; i <= np; i++) {
      p = P[i]; d = p; if (!sub(/\/[^\/]*$/, "", d)) d = "."
      k = H[i] # MUT:dedupe
      k = k "|" mat(dm["@global"]) "|" mat(dm[d]) # MUT:rcdedupe
      if ((p in sf) || gs || rcsdir(dm[d])) k = k "|" p # MUT:sdirdedupe
      if (!(k in rep)) rep[k] = P[i]
      else if (P[i] < rep[k]) { oth[k] = oth[k] (oth[k] == "" ? "" : ", ") rep[k]; rep[k] = P[i] }
      else oth[k] = oth[k] (oth[k] == "" ? "" : ", ") P[i]
    }
    for (k in rep) print rep[k] "\t" oth[k]
  }' "$T/dirrc" "$T/rchash" "$T/sdir" "$T/rcsd" "$T/paths" "$T/hashes" | LC_ALL=C sort > "$T/groups" # MUT:sortpipe
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
shellcheck $X -S "$SEV" $DD "$2" > "$T/o.$1" 2>&1
printf '%s\n' "$?" > "$T/rc.$1"
WORKER
export T
SEV=$sev; export SEV
X=-x; export X # MUT:noxflag
DD=--; export DD # MUT:dashdash
pick_jobs
xargs -0 -n 2 -P "$jobs" bash "$T/worker.sh" < "$T/lint.nul"
# the worker never exits non-zero: any non-zero here is the harness failing.
[ $? -eq 0 ] || { echo "lint: the parallel runner failed" >&2; exit 2; }

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
    *)
      toolerr=$((toolerr + 1))
      echo "lint: TOOL ERROR on ${REP[i]}: shellcheck exit '${rcv:-none}' (not a finding)" >&2
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
