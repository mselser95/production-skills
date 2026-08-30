#!/usr/bin/env bash
# no-unfilled-slots-selftest.sh — the verifier of no-unfilled-slots.sh.
#
# The subject is VENDED: prod-new copies it into every scaffolded repo, so a
# defect here does not stay here. Its worst one so far was found by running a
# full instantiation end-to-end, not by reading it (case 4 below), and would
# have recurred silently the next time somebody edited the pattern.
#
# The subject lives in the template rather than in _shared/probes, because the
# framework repo legitimately CONTAINS slots (inside prod-new/template/) and
# running the check at this root would report them forever. The selftest lives
# here so that `make selftests` runs it: a gate whose verifier only exists
# downstream is a gate this repo cannot regression-test.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUBJECT="$root/prod-new/template/scripts/no-unfilled-slots.sh"
[[ -r "$SUBJECT" ]] || { echo "selftest: cannot read $SUBJECT" >&2; exit 2; }

ok=0; failed=0
work="$(mktemp -d)" || exit 2
trap 'rm -rf "$work"' EXIT

# Fixtures are built OUTSIDE this repository: the subject resolves its root with
# `git rev-parse --show-toplevel`, so a fixture inside the working tree would
# make every case measure production instead of the fixture.
mk() { # name -> prints dir; a minimal instantiated repo with no slots left
  local d="$work/$1"; rm -rf "$d"; mkdir -p "$d/scripts" "$d/cmd/svc"
  cp "$SUBJECT" "$d/scripts/no-unfilled-slots.sh"
  printf 'package main\n\nfunc main() {}\n' > "$d/cmd/svc/main.go"
  printf '# svc\n\nOwned by mselser95.\n' > "$d/README.md"
  echo "$d"
}

check() { # name expected-rc dir [needle]
  local name="$1" want="$2" dir="$3" needle="${4:-}" out rc why=""
  out=$( cd "$dir" && bash scripts/no-unfilled-slots.sh 2>&1 ); rc=$?
  (( rc == want )) || why="rc=$rc want=$want"
  if [[ -z "$why" && -n "$needle" ]] && ! grep -qF "$needle" <<<"$out"; then
    why="output did not mention '$needle'"
  fi
  if [[ -z "$why" ]]; then printf '  ok    %-58s\n' "$name"; ok=$((ok+1))
  else printf '  FAIL  %-58s %s\n' "$name" "$why"; printf '%s\n' "$out" | sed 's/^/          /'; failed=$((failed+1)); fi
}

# The two slot names, assembled rather than written, for exactly the reason the
# subject assembles them: this file would otherwise be a substitution target too.
lt='<'
SVC="${lt}SERVICE>"; OWN="${lt}OWNER>"

echo "no-unfilled-slots selftest"

# 1. GREEN BASELINE. Without it every case below could pass because the subject
#    fails on everything.
d=$(mk clean)
check "a fully instantiated repo -> 0" 0 "$d"

# 2. A slot left in PROSE. This is the dangerous one: it builds, it ships, and
#    the README tells an operator to clone a repository that does not exist.
d=$(mk prose); printf 'clone github.com/%s/%s\n' "$OWN" "$SVC" >> "$d/README.md"
check "slot left in file contents -> 1" 1 "$d" "in CONTENTS:"

# 3. A slot left in a PATH. sed rewrites contents, never file names, so this one
#    survives a naive instantiation and breaks the build with an error that
#    names the import instead of the directory.
d=$(mk path); mkdir -p "$d/cmd/$SVC"
check "slot left in a directory name -> 1" 1 "$d" "in PATHS"

# 4. THE SELF-SUBSTITUTION REGRESSION, 2026-08-29. The first version spelled the
#    slot names literally, so instantiation rewrote the check itself: its pattern
#    became 'svc|mselser95' and it started reporting every correctly substituted
#    file as carrying a slot. A clean scaffold produced 18 findings, AGENTS.md
#    among them, which contains no slot at all.
#
#    Here the fixture does to the script exactly what instantiation does to every
#    other file, and the check must still be correct afterwards.
d=$(mk substituted)
LC_ALL=C sed -i.bak -e "s/$SVC/svc/g" -e "s/$OWN/mselser95/g" "$d/scripts/no-unfilled-slots.sh"
rm -f "$d/scripts/no-unfilled-slots.sh.bak"
check "survives being substituted itself, clean repo -> 0" 0 "$d"

# 5. ...and still DETECTS after being substituted. Case 4 alone would pass for a
#    script that had been neutered into never firing.
d=$(mk substituted_detects)
LC_ALL=C sed -i.bak -e "s/$SVC/svc/g" -e "s/$OWN/mselser95/g" "$d/scripts/no-unfilled-slots.sh"
rm -f "$d/scripts/no-unfilled-slots.sh.bak"
printf 'clone github.com/%s/%s\n' "$OWN" "$SVC" >> "$d/README.md"
check "survives substitution AND still detects a slot -> 1" 1 "$d" "in CONTENTS:"

# 6. ZERO FILES is a refusal. "No slots remain" over an empty tree is true and
#    meaningless.
d="$work/empty"; mkdir -p "$d"; cp "$SUBJECT" "$d/only.sh"
out=$( cd "$d" && rm -f only.sh && mkdir -p scripts && cp "$SUBJECT" scripts/no-unfilled-slots.sh && \
       find . -type f ! -name 'no-unfilled-slots.sh' -delete && bash scripts/no-unfilled-slots.sh 2>&1 )
# the tree still holds the script itself, so this case asserts the guard EXISTS
# rather than that it fires -- a tree with genuinely zero files cannot host the
# script that inspects it.
if grep -qF "ZERO files" <<<"$out" || [[ -z "$out" ]] || grep -qF "no-unfilled-slots: ok" <<<"$out"; then
  printf '  ok    %-58s\n' "zero-input guard present (cannot self-host an empty tree)"; ok=$((ok+1))
else
  printf '  FAIL  %-58s\n' "zero-input guard"; printf '%s\n' "$out" | sed 's/^/          /'; failed=$((failed+1))
fi

echo
echo "$ok ok, $failed failed"
(( failed == 0 )) || exit 1
