#!/usr/bin/env bash
# instantiate-template.sh — turn prod-new/template/ into a real repo, the way
# prod-new's Phase-3 step 1 says to, so CI can prove the vended product works.
#
# WHY THIS EXISTS
#
# This repository's product is a scaffolded repo. Until 2026-08-29 nothing ever
# built one: CI linted the template's WORKFLOW FILES after slot substitution and
# stopped there, so a change that broke the template's Makefile, its fitness
# checks or its Go code would ship green and be discovered by whoever scaffolded
# next. The integration lane existed for install.sh and not for the thing this
# repo is actually for.
#
# Measured by hand the same day, which is what made the job worth wiring: a
# correctly instantiated template reaches `make check-fast` exit 0, and
# `make verify-standard` PASS 64 / FAIL 3 / NA 18 -- where all three FAILs are
# prod-new Phase-3 steps a mechanical copy cannot do (SLO objectives a human
# ratifies, a load baseline that is only meaningful on the target hardware, and
# provenance headers needing a diff base). None is a template defect. So this
# script runs check-fast, which is the part a machine can own.
#
# SLOTS LIVE IN PATHS AS WELL AS CONTENTS. `cmd/<SERVICE>` is a directory, and
# sed rewrites contents only. Substituting the files and stopping there leaves a
# tree whose `go build ./...` dies with `malformed import path ... invalid char
# '<'` -- an error that names the import and sends the reader into go.mod. The
# rename below is not a tidy-up; it is why the build works.
#
# Usage: instantiate-template.sh <dest-dir> [service-name] [owner]
# Exit:  0 instantiated · 2 could not
set -uo pipefail

dest="${1:-}"
svc="${2:-svc}"
owner="${3:-mselser95}"
[[ -n "$dest" ]] || { echo "usage: instantiate-template.sh <dest-dir> [service] [owner]" >&2; exit 2; }

root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
tpl="$root/prod-new/template"
[[ -d "$tpl" ]] || { echo "instantiate: no template at $tpl" >&2; exit 2; }

mkdir -p "$dest" || exit 2
cp -R "$tpl/." "$dest/" || exit 2
# The installed TCB is read-only and cp preserves mode, so a template copied out
# of an installed skill dir arrives read-only and the first substitution fails
# with EACCES. Copy, make writable, then fill -- prod-new says the same.
chmod -R u+w "$dest" || exit 2

cd "$dest" || exit 2

# 1. contents
files=$(grep -rl '<SERVICE>\|<OWNER>' . 2>/dev/null || true)
nf=$(printf '%s' "$files" | grep -c . || true)
if (( nf == 0 )); then
  echo "instantiate: ZERO slot-bearing files found in the template copy." >&2
  echo "  Either the copy failed or the template stopped using slots; both mean this" >&2
  echo "  script would 'succeed' without doing anything. Refusing." >&2
  exit 2
fi
printf '%s\n' "$files" | while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  LC_ALL=C sed -i.bak -e "s/<SERVICE>/$svc/g" -e "s/<OWNER>/$owner/g" "$f" && rm -f "$f.bak"
done

# 2. paths — deepest first, so renaming a parent does not invalidate the child
#    paths still queued behind it.
while IFS= read -r p; do
  [[ -n "$p" ]] || continue
  new="${p//<SERVICE>/$svc}"; new="${new//<OWNER>/$owner}"
  [[ "$new" == "$p" ]] && continue
  mkdir -p "$(dirname "$new")" && mv "$p" "$new"
done < <(find . -depth -name '*<*>*' 2>/dev/null)

# 3. the check that both halves actually landed. A content grep alone reported
#    zero remaining slots while cmd/<SERVICE> was still sitting there.
left_c=$(grep -rl '<SERVICE>\|<OWNER>' . 2>/dev/null | grep -c . || true)
left_p=$(find . -name '*<*>*' 2>/dev/null | grep -c . || true)
if (( left_c + left_p > 0 )); then
  echo "instantiate: slots survived -- ${left_c} file(s), ${left_p} path(s)" >&2
  find . -name '*<*>*' 2>/dev/null | sed 's/^/    path: /' >&2
  grep -rl '<SERVICE>\|<OWNER>' . 2>/dev/null | sed 's/^/    file: /' >&2
  exit 2
fi

echo "instantiate: ok -- ${nf} file(s) substituted, slots remaining: 0 in contents, 0 in paths"
