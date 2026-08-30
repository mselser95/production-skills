#!/usr/bin/env bash
# template-digest-selftest.sh — the verifier of scripts/template-digest.sh.
#
# The subject decides what VERSION every scaffolded repo pins to, and whether a
# change to the vended surface can land unannounced. Both are properties nobody
# downstream can check for themselves, so the cases below are the only place
# they are held to anything.
#
# Fixtures copy the subject into the fixture tree: it resolves its root with
# `cd "$(dirname "$BASH_SOURCE")/.."`, so a fixture built anywhere else would
# make every case measure the real repository instead.
set -uo pipefail

SUBJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/template-digest.sh"
[[ -r "$SUBJECT" ]] || { echo "selftest: cannot read $SUBJECT" >&2; exit 2; }

ok=0; failed=0
work="$(mktemp -d)" || exit 2
trap 'rm -rf "$work"' EXIT

# A minimal repo shaped like this one: a stamper declaring a VENDORED list, the
# files it names, and the subject.
fixture() { # name file1 file2 ... -> prints dir
  local d="$work/$1"; shift
  rm -rf "$d"; mkdir -p "$d/scripts" "$d/prod-new/template/scripts"
  cp "$SUBJECT" "$d/scripts/template-digest.sh"
  { echo 'VENDORED=('
    for f in "$@"; do echo "  $f"; done
    echo ')'
  } > "$d/prod-new/template/scripts/stamp-template-provenance.sh"
  for f in "$@"; do
    mkdir -p "$d/prod-new/template/$(dirname "$f")"
    printf '#!/usr/bin/env bash\necho %s\n' "$f" > "$d/prod-new/template/$f"
  done
  echo "$d"
}

check() { # name want-rc dir [needle] [args...]
  local name="$1" want="$2" dir="$3" needle="${4:-}"; shift 4 2>/dev/null || shift 3
  local out rc why=""
  out=$( cd "$dir" && bash scripts/template-digest.sh "$@" 2>&1 ); rc=$?
  (( rc == want )) || why="rc=$rc want=$want"
  if [[ -z "$why" && -n "$needle" ]] && ! grep -qF "$needle" <<<"$out"; then
    why="output did not mention '$needle'"
  fi
  if [[ -z "$why" ]]; then printf '  ok    %-58s\n' "$name"; ok=$((ok+1))
  else printf '  FAIL  %-58s %s\n' "$name" "$why"; printf '%s\n' "$out" | sed 's/^/          /'; failed=$((failed+1)); fi
}

echo "template-digest selftest"

# 1. NO DIGEST AT ALL is a finding, not a pass. Before anything else, because a
#    subject that reports "in step" over a missing version file would make every
#    case below meaningless.
d=$(fixture nodigest scripts/a.sh scripts/b.sh)
check "no TEMPLATE-DIGEST -> 1, says there is no version" 1 "$d" "the vended template has no version"

# 2. ROUND TRIP: --write then check must agree. This is the green baseline, and
#    without it every red case below could be passing because the subject fails
#    on everything.
d=$(fixture roundtrip scripts/a.sh scripts/b.sh)
( cd "$d" && bash scripts/template-digest.sh --write >/dev/null 2>&1 )
check "after --write, the gate is in step -> 0" 0 "$d" "in step"

# 3. THE POINT OF THE WHOLE THING: a vendored file changes and the digest does
#    not. Must fail AND NAME the file -- a digest that only says "something
#    moved" sends the reader to diff the whole list by hand.
d=$(fixture changed scripts/a.sh scripts/b.sh)
( cd "$d" && bash scripts/template-digest.sh --write >/dev/null 2>&1 )
printf '\n# edited\n' >> "$d/prod-new/template/scripts/b.sh"
check "a vendored file changed -> 1, naming it" 1 "$d" "CHANGED  scripts/b.sh"

# 4. A file ADDED to the vendored list is also a change downstream must see.
d=$(fixture added scripts/a.sh)
( cd "$d" && bash scripts/template-digest.sh --write >/dev/null 2>&1 )
printf '#!/usr/bin/env bash\necho c\n' > "$d/prod-new/template/scripts/c.sh"
sed -i.bak 's|^)|  scripts/c.sh\n)|' "$d/prod-new/template/scripts/stamp-template-provenance.sh"
check "a file added to the vendored list -> 1, marked ADDED" 1 "$d" "ADDED    scripts/c.sh"

# 5. And a file REMOVED from the list, which the per_file block is what makes
#    visible at all.
d=$(fixture removed scripts/a.sh scripts/b.sh)
( cd "$d" && bash scripts/template-digest.sh --write >/dev/null 2>&1 )
sed -i.bak '/scripts\/b.sh/d' "$d/prod-new/template/scripts/stamp-template-provenance.sh"
check "a file removed from the list -> 1, marked REMOVED" 1 "$d" "REMOVED  scripts/b.sh"

# 6. A DECLARED FILE THAT DOES NOT EXIST is a refusal, not a smaller digest.
#    Hashing what remains would produce a value that looks fine while describing
#    a set nobody has.
d=$(fixture missing scripts/a.sh scripts/b.sh)
( cd "$d" && bash scripts/template-digest.sh --write >/dev/null 2>&1 )
rm -f "$d/prod-new/template/scripts/b.sh"
check "a declared file that does not exist -> 2, not a digest" 2 "$d" "do not exist"

# 7. ZERO vendored files is a refusal. A digest over nothing is a constant, and a
#    constant reports "in step" for every future edit forever.
d=$(fixture empty)
check "empty VENDORED list -> 2, not a constant digest" 2 "$d" "ZERO vendored files"

# 8. A DIGEST FILE WITH NO per_file BLOCK -- an older one -- must say it cannot
#    name what moved, not list every file as ADDED. Without the guard, `was` is
#    empty for all of them and the report is a wall of bogus additions with the
#    one real change hidden inside it. Found by mutating the subject and noticing
#    case 4 passed for the wrong reason.
d=$(fixture legacydigest scripts/a.sh scripts/b.sh)
printf 'digest: %064d\nshort: %012d\nfiles: 2\n' 0 0 > "$d/prod-new/TEMPLATE-DIGEST"
check "digest with no per_file block -> 1, says it cannot name" 1 "$d" "predates the per_file block"

echo
echo "$ok ok, $failed failed"
(( failed == 0 )) || exit 1
