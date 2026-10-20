#!/usr/bin/env bash
# template-vendored-list-selftest.sh -- every prod-new/template/scripts/tests/*.sh must be listed
# in stamp-template-provenance.sh's VENDORED array. A template selftest missing from it is never
# stamped, so an edit to it drifts invisibly in every scaffolded repo (3 files went missing that way).
# provenance: candidate
# ttl: 2027-01-20
# TEMPLATE_SCRIPTS=<dir> points at another template scripts/ dir (used by the negative fixture).
# Usage: bash <this>   Exit: 0 all listed, 1 a case failed, 2 cannot run.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
real="${TEMPLATE_SCRIPTS:-$root/prod-new/template/scripts}"
TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT

# unlisted <template-scripts-dir> -> prints each tests/*.sh not in the VENDORED array; rc 2 if unparseable
unlisted() {
  local d="$1" list f n=0
  list=$(sed -n '/^VENDORED=(/,/^)/p' "$d/stamp-template-provenance.sh" | sed 's/#.*//' | awk 'NF && $1 != "VENDORED=(" && $1 != ")" {print $1}')
  [ -n "$list" ] || { echo "cannot parse VENDORED" >&2; return 2; }
  for f in "$d"/tests/*.sh; do
    [ -f "$f" ] || continue
    n=$((n+1))
    grep -qxF "scripts/tests/$(basename "$f")" <<<"$list" || echo "scripts/tests/$(basename "$f")"
  done
  [ "$n" -gt 0 ] || { echo "no template tests found" >&2; return 2; }
  return 0
}

CASES=0; FAILED=0
check() { CASES=$((CASES+1)); if [ "$2" = "$3" ]; then printf '  ok   %-60s %s\n' "$1" "$3"
  else printf '  FAIL %-60s expected=%s actual=%s\n' "$1" "$2" "$3"; FAILED=$((FAILED+1)); fi; }

# real template: nothing unlisted (and the parse worked)
out=$(unlisted "$real"); rc=$?
check "template: every tests/*.sh is in VENDORED (parse rc)" 0 "$rc"
check "template: no unlisted test file" "" "$out"

# negative fixture: copy the template, add a test file nobody lists -> it must be reported
mkdir -p "$TMP/t/tests"
cp "$real/stamp-template-provenance.sh" "$TMP/t/"
cp "$real"/tests/*.sh "$TMP/t/tests/"
echo '#!/bin/sh' > "$TMP/t/tests/zz-new-selftest.sh"
check "NEG: a new unlisted tests/*.sh is reported" "scripts/tests/zz-new-selftest.sh" "$(unlisted "$TMP/t")"

# negative fixture 2: drop a listed entry -> that file is reported
sed '/^  scripts\/tests\/retry-selftest.sh$/d' "$real/stamp-template-provenance.sh" > "$TMP/t/stamp-template-provenance.sh"
rm "$TMP/t/tests/zz-new-selftest.sh"
check "NEG: a de-listed entry is reported" "scripts/tests/retry-selftest.sh" "$(unlisted "$TMP/t")"

# negative fixture 3: an unparseable stamper is rc 2, never a silent pass
echo 'nothing' > "$TMP/t/stamp-template-provenance.sh"
unlisted "$TMP/t" >/dev/null 2>&1; check "NEG: unparseable VENDORED -> rc 2, not a pass" 2 "$?"

if (( FAILED > 0 )); then echo "template-vendored-list selftest: $FAILED of $CASES case(s) FAILED"; exit 1; fi
echo "template-vendored-list selftest: $CASES case(s) passed"
