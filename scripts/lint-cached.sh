#!/usr/bin/env bash
# lint-cached.sh -- `shellcheck` over every tracked *.sh, one file per invocation,
# in parallel, and not at all for a file whose verdict is already proven clean.
#
# THE RULE. A cached verdict is a function of EXACTLY what its key hashes, and the
# key hashes every input that can change shellcheck's verdict for that file:
#   - every file is linted ALONE, always with -x (--external-sources), from the repo
#     root. Without -x shellcheck follows a sourced file only when that file happens
#     to share the command line (so batching changed verdicts); with -x it follows
#     sources always, so the verdict never depends on who else is on the line.
#   - KEY(file) = sha256 of: the key-version constant; THIS SCRIPT's sha256; the
#     arguments ("-x -S <severity>"); the whole `shellcheck --version`; $SHELLCHECK_OPTS;
#     the locale variables; the path+content of the user-level rc files that exist
#     ($HOME/.shellcheckrc, $XDG_CONFIG_HOME/shellcheckrc and the "shellcheck"
#     subdirectory variant); the file's own content sha256; the rc chain (below); and the
#     SOURCES component (below).
#   - RC CHAIN (measured on shellcheck 0.11.0, not guessed): shellcheck looks for a
#     regular file named .shellcheckrc OR shellcheckrc in the linted file's directory
#     and then in every parent directory, ALL THE WAY UP TO / (not only to the repo
#     root), and STOPS AT THE FIRST DIRECTORY that has one: a nearer rc replaces a
#     farther one entirely (even an empty nearer one). A directory or a dangling
#     symlink with that name is skipped and the search continues; a symlink to a
#     file counts. The key holds path+content of the rc file(s) found in that first
#     directory (both names, if both exist), tracked or not.
#   - SOURCES component: a file that contains no `source` word, no `.` command word
#     and no `# shellcheck source=` directive (a textual test that only over-matches:
#     a comment saying "source" costs a cache hit, it never loses an input) cannot
#     have shellcheck open another file: its component is empty. Any other file is a
#     SOURCING file: its key also holds the sha256 of the sorted path+content of ALL
#     tracked *.sh files, and its own directory (a relative source resolves against
#     it), so a change anywhere re-lints every sourcing file: coarse but sound.
#   - DEDUPLICATION: two paths share a verdict only if their whole KEY is equal. The
#     representative is the first path in byte order; its findings are printed under
#     its path, followed by the other paths that share its key.
#
# ONLY A CLEAN RESULT IS CACHED (shellcheck exit 0). An entry is a regular file in the
# cache dir named by the key whose whole content is "lint-ok <key>"; an empty file, a
# directory, a symlink or any other content is ignored and the file is re-linted.
# Entries are written to a temp dir inside the cache dir and renamed (atomic). A
# cache dir that is a symlink or not a directory is refused (exit 2).
#
# WHAT IT CANNOT SEE: a sourced file that is not a tracked *.sh (an untracked file,
# a tracked file without the .sh suffix, a file outside the repo such as
# /etc/profile): editing it does not re-lint its sourcers; use LINT_CACHE=off when
# that matters. A command name obfuscated beyond the textual test (sou""rce is not
# followed by shellcheck either); env vars shellcheck reads that are not listed above.
# Paths containing a newline or a tab are refused (exit 2).
#
# Versus the old recipe (one `shellcheck -S warning` over all files, no -x): a verdict
# equal or stricter -- a sourced file on the command line is followed by both, and -x
# follows it also when it is not.
#
# Usage: lint-cached.sh            (from anywhere inside the work tree)
# Env:
#   LINT_CACHE=on|off|verify   on (default): read and store. off: lint everything,
#                              do not read the cache, DO store clean results.
#                              verify: lint cached entries too; one that now has
#                              findings is a CACHE LIE: entry deleted, exit 3.
#   LINT_CACHE_DIR   default .cache/lint, relative to the repo root.
#   LINT_JOBS        parallel shellcheck processes: default min(4, cores), and no
#                    more than a cgroup v2 CPU quota.
#   LINT_SEVERITY    default warning (the -S argument).
# Exit: 0 every unique script clean; 1 findings; 2 tool or usage error (shellcheck
# missing, zero files, unreadable input, shellcheck exit >= 2 or killed, cache dir
# refused); 3 CACHE LIE. A tool error is never cached and never reported as findings;
# when several apply, 2 wins over 3 over 1.
#
# PROCESSES when everything is cached (any file count; asserted by the selftest): a
# fixed number of git, shasum, xargs, grep, awk, sort, tr; no per-file fork.
set -uo pipefail

KEYV=lint-cache-key-v2
sev=${LINT_SEVERITY:-warning}
mode=${LINT_CACHE:-on}
case $mode in on | off | verify) ;; *) echo "lint: LINT_CACHE must be on|off|verify (got '$mode')" >&2; exit 2 ;; esac

command -v shellcheck >/dev/null || { echo "shellcheck missing -- brew install shellcheck" >&2; exit 2; }
case ${BASH_SOURCE[0]} in /*) self=${BASH_SOURCE[0]} ;; *) self=$PWD/${BASH_SOURCE[0]} ;; esac
root=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "lint: not inside a git work tree" >&2; exit 2; }
case $root in *$'\n'* | *$'\t'*) echo "lint: a repo path with a newline or tab is unsupported" >&2; exit 2 ;; esac
cd "$root" || exit 2

jobs=${LINT_JOBS:-}
if [ -z "$jobs" ]; then
  jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null) || jobs=""
  case $jobs in '' | *[!0-9]*) jobs=$(sysctl -n hw.ncpu 2>/dev/null) || jobs="" ;; esac
  case $jobs in '' | *[!0-9]* | 0) jobs=2 ;; esac
  [ "$jobs" -le 4 ] || jobs=4
  # a container's CPU quota (cgroup v2) is invisible to getconf, which reports the
  # host's cores; oversubscribing the quota made the cold run slower (measured).
  if [ -r /sys/fs/cgroup/cpu.max ] && read -r quota period < /sys/fs/cgroup/cpu.max; then
    case $quota$period in
      *[!0-9]*) ;;
      *) quota=$(((quota + period - 1) / period)); [ "$quota" -lt 1 ] || [ "$jobs" -le "$quota" ] || jobs=$quota ;;
    esac
  fi
fi
case $jobs in *[!0-9]*) echo "lint: LINT_JOBS must be an integer" >&2; exit 2 ;; esac
[ "$jobs" -ge 1 ] || { echo "lint: LINT_JOBS must be >= 1" >&2; exit 2; }

if command -v shasum >/dev/null; then SHA=(shasum -a 256)
elif command -v sha256sum >/dev/null; then SHA=(sha256sum)
else echo "lint: neither shasum nor sha256sum found" >&2; exit 2; fi

# ---- the cache dir: refuse a symlink or a non-directory ------------------------------
cache=${LINT_CACHE_DIR:-.cache/lint}
case $cache in /*) ;; *) cache="$root/$cache" ;; esac
if [ -L "$cache" ] || { [ -e "$cache" ] && [ ! -d "$cache" ]; }; then
  echo "lint: cache dir '$cache' is a symlink or not a directory -- refusing" >&2; exit 2
fi
usable=1
if [ -d "$cache" ] && [ -r "$cache" ] && [ -w "$cache" ]; then :
elif [ -e "$cache" ] || ! mkdir -p "$cache" 2>/dev/null; then
  echo "lint: WARNING cache dir '$cache' is not writable: linting everything uncached" >&2
  usable=0
fi

T=$(mktemp -d "${TMPDIR:-/tmp}/lint-cached.XXXXXX") || exit 2
STAGE=""
cleanup() {
  case $T in */lint-cached.*) rm -rf -- "$T" ;; esac
  [ -z "$STAGE" ] || rm -rf -- "$STAGE"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ---- input set: NUL-safe ---------------------------------------------------------------
git ls-files -z '*.sh' > "$T/files0" || exit 2
if ! [ -s "$T/files0" ]; then
  echo "lint: found ZERO shell scripts -- a clean lint over nothing is not a clean lint" >&2; exit 2 # MUT:zeroguard
fi
if [ "$(tr -d -c '\n\t' < "$T/files0" | wc -c | tr -d ' ')" != 0 ]; then
  echo "lint: a tracked *.sh path contains a newline or a tab -- unsupported, refusing" >&2; exit 2
fi
tr '\0' '\n' < "$T/files0" > "$T/paths"
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
      if [ -n "$f1$f2" ]; then # MUT:rcchain
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

# ---- which files can source another (textual, over-matching) -------------------------
# The linter follows only a simple command whose command word is the literal `.` or
# `source` (not `command .`, `builtin source`, a quoted or split word: measured), or a
# `# shellcheck source=` directive. So a SOURCING file is one with, on a line that is
# not a pure comment: the word source; or a `.` word followed by an operand (optional
# redirections skipped; a trailing backslash counts as an operand); or a word char
# glued to a line-ending backslash (a split word); or, on ANY line, a shellcheck
# directive mentioning source. A line that is only a comment can follow nothing.
awk '
  BEGIN {
    SRC = "(^|[^[:alnum:]_])source($|[^[:alnum:]_])"
    DOT = "(^|[^[:alnum:]_./~*-])\\.([[:space:]]+([0-9]*(>>?|<<?<?|&>>?)&?[^[:space:]]*[[:space:]]+)*([^[:space:][:digit:]<>|;&)#]|[[:digit:]]+([^[:space:][:digit:]<>]|[[:space:]]|$))|[[:space:]]*\\\\$)"
    CONT = "[[:alnum:]_\"" sprintf("%c", 39) "]\\\\$"
  }
  {
    f = $0; hit = 0
    while ((r = (getline line < f)) > 0) {
      t = line; sub(/^[[:space:]]+/, "", t)
      if (t ~ /shellcheck[[:space:]].*source/) { hit = 1; break }
      if (t == "" || substr(t, 1, 1) == "#") continue
      if (t ~ SRC || t ~ DOT || t ~ CONT) { hit = 1; break }
    }
    if (r < 0) { print "cannot read " f > "/dev/stderr"; bad = 1 }
    close(f)
    if (hit) print f
  }
  END { exit bad }
' "$T/paths" > "$T/srcfiles" 2> "$T/grep.err" || { echo "lint: could not scan for sourcing:" >&2; head -3 "$T/grep.err" >&2; exit 2; }
# the SOURCES component: every tracked *.sh, path and content
awk 'FILENAME == ARGV[1] { p[++n] = $0; next }
     { s = $0; if (substr(s, 1, 1) == "\\") s = substr(s, 2); print p[++m] "\t" substr(s, 1, 64) }' "$T/paths" "$T/hashes" | LC_ALL=C sort | "${SHA[@]}" | cut -c1-64 > "$T/srcsha"

# ---- the key header --------------------------------------------------------------------
vers=$(shellcheck --version 2>&1) || { echo "lint: shellcheck --version failed" >&2; exit 2; }
selfsha=$("${SHA[@]}" < "$self" | cut -c1-64) || exit 2
{
  printf '%s\n' "$KEYV"
  printf 'script=%s\n' "$selfsha" # MUT:selfkey
  printf 'args=-x -S %s\n' "$sev" # MUT:sevkey
  printf 'version=%s\n' "$vers" # MUT:verkey
  printf 'opts=%s\n' "${SHELLCHECK_OPTS:-}"
  printf 'locale=%s|%s|%s\n' "${LC_ALL:-}" "${LC_CTYPE:-}" "${LANG:-}"
} > "$T/hdr"

# ---- one key per file ------------------------------------------------------------------
mkdir "$T/km"
KM="$T/km" ROOT="$root" LC_ALL=C awk -F'\t' '
  function rel(p) { return index(p, ENVIRON["ROOT"] "/") == 1 ? substr(p, length(ENVIRON["ROOT"]) + 2) : p }
  function mat(line,   a, k, out, i) {
    k = split(line, a, "\t"); out = ""
    for (i = 2; i <= k; i++) out = out "rc=" rel(a[i]) ":" rh[a[i]] "\n"
    return out
  }
  FILENAME == ARGV[1] { hdr = hdr $0 "\n"; next }
  FILENAME == ARGV[2] { split($0, a, "\t"); dm[a[1]] = $0; next }   # resolved in END: the rc hashes arrive in the next file
  FILENAME == ARGV[3] { rh[$1] = $2; next }
  FILENAME == ARGV[4] { sf[$0] = 1; next }
  FILENAME == ARGV[5] { ss = $0; next }
  FILENAME == ARGV[6] { P[++np] = $0; next }
  { s = $0; if (substr(s, 1, 1) == "\\") s = substr(s, 2); H[++nh] = substr(s, 1, 64) }
  END {
    if (np != nh) { print "MISMATCH"; exit }
    for (i = 1; i <= np; i++) {
      p = P[i]; d = p; if (!sub(/\/[^\/]*$/, "", d)) d = "."
      f = ENVIRON["KM"] "/" sprintf("%08d", i)
      printf "%s", hdr > f
      printf "global-rc=\n%s", mat(dm["@global"]) > f
      printf "content=%s\n", H[i] > f # MUT:contentkey
      printf "chain=\n%s", mat(dm[d]) > f
      flag = (p in sf) ? 1 : 0 # MUT:srcclass
      if (flag) printf "sources=%s\ndir=%s\n", ss, d > f # MUT:srcdir
      else printf "sources=none\n" > f
      close(f)
      print p "\t" flag > (ENVIRON["KM"] "/meta")
    }
    print "OK", np
  }' "$T/hdr" "$T/dirrc" "$T/rchash" "$T/srcfiles" "$T/srcsha" "$T/paths" "$T/hashes" > "$T/kmres" || exit 2
read -r kstat knum < "$T/kmres"
if [ "$kstat" != OK ] || [ "$knum" -eq 0 ]; then
  echo "lint: could not pair the file list with its hashes" >&2; exit 2
fi
mv "$T/km/meta" "$T/meta"
printf '%s\0' "$T/km/"[0-9]* | xargs -0 "${SHA[@]}" -- | cut -c1-64 > "$T/keys"
[ "$(grep -c . "$T/keys")" -eq "$knum" ] || { echo "lint: key hashing failed" >&2; exit 2; }

# ---- group by KEY; representative = first path in byte order -------------------------
LC_ALL=C awk -F'\t' '
  FILENAME == ARGV[1] { P[++n] = $1; F[n] = $2; next }
  { K[++m] = $0 }
  END {
    for (i = 1; i <= n; i++) {
      k = K[i] # MUT:dedupe
      if (!(k in rep)) { rep[k] = P[i]; fl[k] = F[i]; order[++u] = k }
      else { if (P[i] < rep[k]) { oth[k] = oth[k] (oth[k] == "" ? "" : ", ") rep[k]; rep[k] = P[i] } else oth[k] = oth[k] (oth[k] == "" ? "" : ", ") P[i] }
    }
    for (j = 1; j <= u; j++) { k = order[j]; print rep[k] "\t" k "\t" fl[k] "\t" oth[k] } # MUT:sortout
  }' "$T/meta" "$T/keys" | LC_ALL=C sort > "$T/groups" # MUT:sortpipe
n=$knum
u=$(grep -c . "$T/groups")
if [ "$n" -eq 0 ]; then echo "lint: found ZERO shell scripts -- a clean lint over nothing is not a clean lint" >&2; exit 2; fi # MUT:zeroguard2
if [ "$u" -eq 0 ]; then echo "lint: deduped to ZERO files -- refusing to report clean over nothing" >&2; exit 2; fi # MUT:zeroguard3

# ---- cache lookup (builtins only: no fork per entry) ----------------------------------
valid_entry() { # key: a regular, non-symlink file whose whole content is "lint-ok <key>"
  local f=$cache/$1 a
  [ -f "$f" ] && [ ! -L "$f" ] || return 1 # MUT:entryexists
  { IFS= read -r a && ! IFS= read -r _; } < "$f" 2> /dev/null || return 1
  [ "$a" = "lint-ok $1" ]
}
c=0; nsrc=0; L=0
REP=(); KEY=(); OTH=(); HIT=()
: > "$T/lint.nul"
while IFS=$'\t' read -r rep key flag others; do
  [ "$flag" != 1 ] || nsrc=$((nsrc + 1))
  hit=0
  if [ "$mode" != off ] && [ "$usable" = 1 ] && valid_entry "$key"; then hit=1; fi # MUT:keyhit
  if [ "$hit" = 1 ] && [ "$mode" != verify ]; then c=$((c + 1)); continue; fi # MUT:verify
  L=$((L + 1)); REP[L]=$rep; KEY[L]=$key; OTH[L]=$others; HIT[L]=$hit
  printf '%s\0%s\0' "$L" "$rep" >> "$T/lint.nul"
done < "$T/groups"
l=$L

# ---- lint the rest: ONE file per shellcheck, with -x, in parallel --------------------
cat > "$T/worker.sh" <<'WORKER'
# $1 = index, $2 = path. Output and exit code go to files; never to the shared stdout.
shellcheck -x -S "$SEV" -- "$2" > "$T/o.$1" 2>&1 # MUT:noxflag
printf '%s\n' "$?" > "$T/rc.$1"
WORKER
export T
SEV=$sev; export SEV
if [ "$L" -gt 0 ]; then
  xargs -0 -n 2 -P "$jobs" bash "$T/worker.sh" < "$T/lint.nul"
  # the worker never exits non-zero: any non-zero here is the harness failing.
  [ $? -eq 0 ] || { echo "lint: the parallel runner failed" >&2; exit 2; }
fi

# ---- verdicts, in representative path order (so stdout is the same for any LINT_JOBS)
dirty=0; toolerr=0; lies=0; verified=0
: > "$T/store"
i=1
while [ "$i" -le "$L" ]; do
  rcv=""
  read -r rcv < "$T/rc.$i" 2> /dev/null || rcv=""
  case $rcv in
    0) # MUT:rc0
      if [ "${HIT[i]}" = 1 ]; then verified=$((verified + 1)); else printf '%s\n' "${KEY[i]}" >> "$T/store"; fi
      ;;
    1) # MUT:rc1
      cat "$T/o.$i"
      [ -z "${OTH[i]}" ] || printf 'lint: the same verdict holds for %s\n' "${OTH[i]}"
      if [ "${HIT[i]}" = 1 ]; then
        lies=$((lies + 1)); rm -rf -- "${cache:?}/${KEY[i]}"
        echo "CACHE LIE: ${REP[i]} was cached clean but now has findings -- entry deleted; the cache key is missing an input" >&2
      else
        dirty=$((dirty + 1)) # MUT:storeall
      fi
      ;;
    *)
      toolerr=$((toolerr + 1))
      echo "lint: TOOL ERROR on ${REP[i]}: shellcheck exit '${rcv:-none}' (not a finding; nothing cached)" >&2
      head -c 400 "$T/o.$i" 2> /dev/null >&2
      ;;
  esac
  i=$((i + 1))
done

# ---- record clean results: temp dir in the cache dir, then rename --------------------
if [ "$usable" = 1 ] && [ -s "$T/store" ]; then
  STAGE="$cache/.tmp.$$"
  rm -rf -- "$STAGE"
  if mkdir "$STAGE" 2> /dev/null; then
    batch=()
    while IFS= read -r key; do
      if [ -e "$cache/$key" ] || [ -L "$cache/$key" ]; then rm -rf -- "${cache:?}/$key"; fi # a forged or stale entry
      printf 'lint-ok %s\n' "$key" > "$STAGE/$key" 2> /dev/null || continue
      batch+=("$STAGE/$key")
      if [ "${#batch[@]}" -ge 200 ]; then mv -f -- "${batch[@]}" "$cache/" 2> /dev/null; batch=(); fi
    done < "$T/store"
    if [ "${#batch[@]}" -gt 0 ]; then mv -f -- "${batch[@]}" "$cache/" 2> /dev/null; fi
  fi
fi

if [ "$toolerr" -gt 0 ]; then
  echo "lint: $toolerr tool error(s): the lint did not complete -- exit 2" >&2
  exit 2
fi
if [ "$lies" -gt 0 ]; then exit 3; fi
if [ "$dirty" -gt 0 ]; then
  echo "shellcheck: findings in $dirty of $u unique script(s) at severity=$sev (cached $c, linted $l)" >&2
  exit 1
fi
extra=""; [ "$mode" != verify ] || extra="; verified $verified cached"
echo "shellcheck: $u unique script(s) of $n clean at severity=$sev (cached $c, linted $l; sourcing $nsrc$extra)"
