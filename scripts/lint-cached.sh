#!/usr/bin/env bash
# lint-cached.sh -- `shellcheck` over every tracked *.sh, once per distinct CONTENT,
# in parallel, and not at all for content it has already proven clean.
#
# WHY. `make lint` ran shellcheck serially over 174 tracked scripts (6 MB) on every
# commit and every CI run: 135 s on one core of a 16-core box, the largest part of
# `make check-fast`. The rule of this repo is that a check finishes in seconds and
# does not re-run when what it reads did not change. A script is text: its verdict
# is a function of its bytes, the tool and the flags, nothing else.
#
# WHAT IT LINTS. Exactly what the old recipe did: `git ls-files '*.sh'` (TRACKED
# FILES ONLY, working-tree content, so an unstaged edit is seen and an untracked
# scratch file is not), grouped by sha256 (DEDUPED BY CONTENT: install.sh mirrors
# the shared probes into nine skills), ONE representative per distinct content.
# Zero files, or zero after dedup, is exit 2: a clean lint over nothing is not a
# clean lint.
#
# THE KEY. An entry is a marker file named  <P>-<C>  in the cache dir where
#   P = first 32 hex of sha256 over: "lint-cache-key-v1", the exact shellcheck
#       argument string ("-S <severity>"), `shellcheck --version` output (whole),
#       $SHELLCHECK_OPTS, and path+content of every tracked .shellcheckrc plus
#       the root .shellcheckrc if present (today: none exists);
#   C = sha256 of the file's working-tree content.
# (P is hashed once per run; C comes from the one batched hash pass, so a run does
# not fork per file.) A tool upgrade, a changed severity, a changed rc file or a
# changed content is a different name: a miss, never a stale hit.
#
# ONLY A CLEAN RESULT IS CACHED (shellcheck exit 0 for that file). A file with
# findings is never cached and its findings are printed on every run. A failed
# batch is re-run file by file so one dirty file cannot stop its batch-mates from
# being recorded clean, and its output is the per-file output.
#
# SOURCED FILES. The decision is: shellcheck is invoked WITHOUT -x, so it never
# opens a sourced file and a file's verdict cannot depend on one; the `# shellcheck
# source=` directives are inert (8 tracked files carry one today, all unaffected).
# Should that ever change (SHELLCHECK_OPTS or a tracked .shellcheckrc turns on -x /
# external-sources), a file carrying a `shellcheck ... source` directive is NOT
# CACHED AT ALL in that run (it is linted every time) rather than keyed on its
# sources.
#
# WHAT IT CANNOT SEE. A shellcheck behaviour that depends on something outside
# this list (a `~/.shellcheckrc` in $HOME, XDG config, an env var other than
# SHELLCHECK_OPTS). Use LINT_CACHE=off on a machine where that is in play. Paths
# with a newline in them are unsupported (as they always were here).
#
# Usage: lint-cached.sh            (from anywhere inside the work tree)
# Env:
#   LINT_CACHE=on|off|verify   on (default): read and store. off: lint everything,
#                              do not read the cache, DO store clean results.
#                              verify: lint cached entries too; one that now has
#                              findings is a CACHE LIE: entry deleted, exit 3.
#   LINT_CACHE_DIR   default .cache/lint, relative to the repo root.
#   LINT_JOBS        parallel shellcheck processes: default detected cores, max 4,
#                    and no more than a cgroup v2 CPU quota.
#   LINT_BATCH       files per shellcheck process (default 3).
#   LINT_SEVERITY    default warning (the -S argument).
# Exit: 0 every unique content clean; 1 findings; 2 usage / zero files / tool
# missing / cannot read a tracked file; 3 CACHE LIE.
#
# PROCESSES when everything is cached (any file count; asserted by the selftest):
# git x2, shasum (xargs batches, one for any realistic count), shellcheck --version,
# ls, awk x2, sort, plus bash/xargs/cat/tr plumbing. No per-file fork.
set -uo pipefail

sev=${LINT_SEVERITY:-warning}
mode=${LINT_CACHE:-on}
batch=${LINT_BATCH:-3}
case $mode in on | off | verify) ;; *) echo "lint: LINT_CACHE must be on|off|verify (got '$mode')" >&2; exit 2 ;; esac

command -v shellcheck >/dev/null || { echo "shellcheck missing -- brew install shellcheck" >&2; exit 2; }
root=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "lint: not inside a git work tree" >&2; exit 2; }
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
case $jobs$batch in *[!0-9]*) echo "lint: LINT_JOBS and LINT_BATCH must be integers" >&2; exit 2 ;; esac
[ "$jobs" -ge 1 ] && [ "$batch" -ge 1 ] || { echo "lint: LINT_JOBS and LINT_BATCH must be >= 1" >&2; exit 2; }

if command -v shasum >/dev/null; then SHA=(shasum -a 256)
elif command -v sha256sum >/dev/null; then SHA=(sha256sum)
else echo "lint: neither shasum nor sha256sum found" >&2; exit 2; fi

T=$(mktemp -d "${TMPDIR:-/tmp}/lint-cached.XXXXXX") || exit 2
cleanup() { case $T in */lint-cached.*) rm -rf -- "$T" ;; esac; }
trap cleanup EXIT
trap 'exit 130' INT TERM

# ---- input set and one hash pass --------------------------------------------------
git ls-files -z '*.sh' > "$T/files0" || exit 2
if ! [ -s "$T/files0" ]; then
  echo "lint: found ZERO shell scripts -- a clean lint over nothing is not a clean lint" >&2; exit 2 # MUT:zeroguard
fi
if ! xargs -0 "${SHA[@]}" < "$T/files0" > "$T/hashes" 2> "$T/hash.err"; then
  echo "lint: cannot hash a tracked file (deleted from the tree?):" >&2; head -3 "$T/hash.err" >&2; exit 2
fi

# ---- the key prefix ----------------------------------------------------------------
vers=$(shellcheck --version 2>&1) || { echo "lint: shellcheck --version failed" >&2; exit 2; }
rcs=$(git ls-files -z '.shellcheckrc' '*/.shellcheckrc' | tr '\0' '\n')
[ ! -f .shellcheckrc ] || case $'\n'$rcs$'\n' in *$'\n.shellcheckrc\n'*) ;; *) rcs=".shellcheckrc"$'\n'$rcs ;; esac
xsrc=0
case ${SHELLCHECK_OPTS:-} in *-x* | *external-sources*) xsrc=1 ;; esac
{
  printf 'lint-cache-key-v1\n'
  printf 'args=-S %s\n' "$sev" # MUT:sevkey
  printf 'version=%s\n' "$vers" # MUT:verkey
  printf 'opts=%s\n' "${SHELLCHECK_OPTS:-}"
  if [ -n "$rcs" ]; then
    printf '%s\n' "$rcs" | while IFS= read -r rc; do
      [ -n "$rc" ] || continue
      printf 'rc=%s\n' "$rc"; cat -- "$rc"
      if grep -q 'external-sources[[:space:]]*=[[:space:]]*true' "$rc"; then : > "$T/xsrc"; fi
    done
  fi
} > "$T/keyin"
[ ! -e "$T/xsrc" ] || xsrc=1
prefix=$("${SHA[@]}" < "$T/keyin" | cut -c1-32)

: > "$T/nocache"
if [ "$xsrc" = 1 ]; then
  xargs -0 grep -lE 'shellcheck[[:space:]].*source' < "$T/files0" > "$T/nocache" 2>/dev/null || :
fi

# ---- the cache dir -----------------------------------------------------------------
cache=${LINT_CACHE_DIR:-.cache/lint}
case $cache in /*) ;; *) cache="$root/$cache" ;; esac
usable=1
if [ -d "$cache" ] && [ -r "$cache" ] && [ -w "$cache" ]; then :
elif [ -e "$cache" ] || ! mkdir -p "$cache" 2>/dev/null; then
  echo "lint: WARNING cache dir '$cache' is unusable (not a directory / not writable): linting everything uncached" >&2
  usable=0
fi
: > "$T/cachelist"
if [ "$usable" = 1 ] && [ "$mode" != off ]; then
  ls -1 "$cache" > "$T/cachelist" 2>/dev/null || : > "$T/cachelist"
fi

# ---- group by content, split into cached / to-lint ----------------------------------
# mode off: cachelist is empty, so nothing is a hit. verify: hits are re-linted.
LC_ALL=C awk -v prefix="$prefix" -v mode="$mode" -v list="$T/lintlist" -v map="$T/map" '
  FILENAME == ARGV[1] { have[$0] = 1; next }
  FILENAME == ARGV[2] { nc[$0] = 1; next }
  {
    h = substr($0, 1, 64); p = substr($0, 67); n++
    g = h # MUT:dedupe
    if (!(g in rep) || p < rep[g]) { rep[g] = p; hh[g] = h }
  }
  END {
    printf "" > list
    for (g in rep) {
      u++; h = hh[g]
      hit = ((prefix "-" h) in have) && !(rep[g] in nc) ? 1 : 0 # MUT:keyhit
      if (hit && mode != "verify") c++ # MUT:verify
      else print rep[g] > list
      if (hit && mode == "verify") v++
      print rep[g] "\t" h "\t" hit > map # MUT:keymap
    }
    print n + 0, u + 0, c + 0, v + 0
  }' "$T/cachelist" "$T/nocache" "$T/hashes" > "$T/counts" || exit 2
read -r n u c v < "$T/counts"
if [ "$n" -eq 0 ]; then echo "lint: found ZERO shell scripts -- a clean lint over nothing is not a clean lint" >&2; exit 2; fi # MUT:zeroguard2
if [ "$u" -eq 0 ]; then echo "lint: deduped to ZERO files -- refusing to report clean over nothing" >&2; exit 2; fi # MUT:zeroguard3
l=$((u - c))

# ---- lint the rest, in parallel, deterministic output ------------------------------
LC_ALL=C sort "$T/lintlist" > "$T/lintsorted"
cat > "$T/worker.sh" <<'WORKER'
# one xargs batch: output to its own file, never to the shared stdout.
o="$T/o.$$"
if shellcheck -S "$SEV" "$@" > "$o" 2>&1; then
  printf '%s\n' "$@" >> "$T/clean.$$"
else
  [ "$#" -gt 1 ] || { printf '%s\n' "$1" >> "$T/dirty.$$"; printf '%s\n' "$1" > "$T/k.$$"; exit 0; }
  : > "$o"
  for f in "$@"; do
    if shellcheck -S "$SEV" "$f" >> "$o" 2>&1; then printf '%s\n' "$f" >> "$T/clean.$$"
    else printf '%s\n' "$f" >> "$T/dirty.$$"; fi
  done
fi
printf '%s\n' "$1" > "$T/k.$$"
WORKER
export T
SEV=$sev; export SEV
if [ -s "$T/lintsorted" ]; then
  tr '\n' '\0' < "$T/lintsorted" | xargs -0 -n "$batch" -P "$jobs" bash "$T/worker.sh"
  # xargs exits 123 when a worker exited non-zero; the worker never does, so any
  # non-zero here is the harness failing, not a finding.
  [ "${PIPESTATUS[1]}" -eq 0 ] || { echo "lint: the parallel runner failed" >&2; exit 2; }
fi

# findings and shellcheck output, in path order of each batch's first file
: > "$T/order"
for kf in "$T"/k.*; do
  [ -e "$kf" ] || continue
  IFS= read -r first < "$kf"
  printf '%s\t%s\n' "$first" "${kf##*/k.}" >> "$T/order"
done
if [ -s "$T/order" ]; then
  LC_ALL=C sort "$T/order" | while IFS=$'\t' read -r _ pid; do cat "$T/o.$pid"; done
fi
cat "$T"/clean.* > "$T/clean" 2>/dev/null || : > "$T/clean"
cat "$T"/dirty.* > "$T/dirty" 2>/dev/null || : > "$T/dirty"

# ---- record clean results, detect lies ----------------------------------------------
LC_ALL=C awk -F'\t' '
  FILENAME == ARGV[1] { cl[$0] = 1; next }
  FILENAME == ARGV[2] { di[$0] = 1; next }
  {
    if (($1 in cl) && $3 == 0) print "S\t" $2 # MUT:storeall
    if (($1 in di) && $3 == 1) print "L\t" $2 "\t" $1
  }
' "$T/clean" "$T/dirty" "$T/map" > "$T/post"

if [ "$usable" = 1 ]; then
  while IFS=$'\t' read -r kind h; do
    [ "$kind" = S ] || continue
    printf 'ok\n' > "$cache/.tmp.$$.$h" 2>/dev/null && mv -f "$cache/.tmp.$$.$h" "$cache/$prefix-$h" 2>/dev/null || rm -f "$cache/.tmp.$$.$h"
  done < "$T/post"
fi

lies=0
while IFS=$'\t' read -r kind h p; do
  [ "$kind" = L ] || continue
  lies=$((lies + 1))
  rm -f "$cache/$prefix-$h"
  echo "CACHE LIE: $p was cached clean but now has findings -- entry deleted; the cache key is missing an input" >&2
done < "$T/post"

d=$(grep -c . "$T/dirty")
if [ "$lies" -gt 0 ]; then exit 3; fi
if [ "$d" -gt 0 ]; then
  echo "shellcheck: findings in $d of $u unique script(s) at severity=$sev (cached $c, linted $l)" >&2
  exit 1
fi
extra=""; [ "$mode" != verify ] || extra="; verified $v cached"
echo "shellcheck: $u unique script(s) of $n clean at severity=$sev (cached $c, linted $l$extra)"
