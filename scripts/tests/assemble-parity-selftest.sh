#!/usr/bin/env bash
# assemble-parity-selftest.sh -- scripts/assemble.py --layout single must equal
# scripts/instantiate-template.sh byte for byte (contents, paths, modes), and
# must refuse what instantiate refuses. Hermetic, sequential, no network.
# ASSEMBLE=<path> runs another copy of the assembler (mutation proofs).
# Exit: 0 all ok - 1 a case failed - 2 zero cases ran.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
asm="${ASSEMBLE:-$here/scripts/assemble.py}"
inst="$here/scripts/instantiate-template.sh"
mods="$here/prod-new/modules"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/assemble-parity.XXXXXX")" || exit 2
trap 'rm -rf "$tmp"' EXIT

ok=0; bad=0
pass() { ok=$((ok + 1)); echo "ok   $1"; }
fail() { bad=$((bad + 1)); echo "FAIL $1${2:+ -- $2}"; }
A() { python3 -I -B "$asm" --modules-dir "${MODS:-$mods}" "$@"; }
modes() { (cd "$1" && find . -type f -exec ls -ld {} + | awk '{print substr($1,1,10), $NF}' | LC_ALL=C sort); }

parity() { # <label> <svc> <owner>
  local d="$tmp/$1"
  A --dest "$d/a" --layout single --module service-go --slot "SERVICE=$2" --slot "OWNER=$3" >/dev/null 2>"$d.err" \
    || { fail "$1 assemble" "$(head -c 200 "$d.err")"; return; }
  bash "$inst" "$d/b" "$2" "$3" >/dev/null 2>&1 || { fail "$1 instantiate failed"; return; }
  if diff -r "$d/a" "$d/b" >"$d.diff" 2>&1; then pass "$1 diff -r empty"; else fail "$1 diff -r" "$(head -c 200 "$d.diff")"; fi
  if [[ "$(modes "$d/a")" == "$(modes "$d/b")" ]] && [[ -n "$(modes "$d/a")" ]]; then
    pass "$1 file modes equal"
  else fail "$1 file modes differ"; fi
}

parity p1 payments acme
parity p2 order-book some-org

# placement glob dropped from a COPY of the manifest -> a file is unplaced -> refused
mkdir -p "$tmp/m/prod-new/modules/service-go"
ln -s "$here/prod-new/template" "$tmp/m/prod-new/template"
grep -v '"scripts/\*\*"' "$mods/service-go/module.json" >"$tmp/m/prod-new/modules/service-go/module.json"
if MODS="$tmp/m/prod-new/modules" A --dest "$tmp/g" --layout single --module service-go --slot SERVICE=x --slot OWNER=y >/dev/null 2>"$tmp/g.err"; then
  fail "dropped glob not detected" "assemble succeeded"
elif grep -q 'unplaced: scripts/' "$tmp/g.err" && [[ ! -e "$tmp/g" ]]; then pass "dropped glob RED (unplaced, nothing written)"
else fail "dropped glob" "$(head -c 200 "$tmp/g.err")"; fi

# leftover <SLOT> in a path: scratch template copy with an undeclared slot in a path
mkdir -p "$tmp/s/prod-new/modules"
cp -R "$here/prod-new/template" "$tmp/s/prod-new/template"
cp -R "$mods/service-go" "$tmp/s/prod-new/modules/service-go"
mkdir -p "$tmp/s/prod-new/template/cmd/<BOGUS>" && : >"$tmp/s/prod-new/template/cmd/<BOGUS>/main.go"
if MODS="$tmp/s/prod-new/modules" A --dest "$tmp/l" --layout single --module service-go --slot SERVICE=x --slot OWNER=y >/dev/null 2>"$tmp/l.err"; then
  fail "leftover slot in path accepted"
elif grep -q 'path: .*<BOGUS>' "$tmp/l.err"; then pass "leftover <SLOT> in path refused, path named"
else fail "leftover slot message" "$(head -c 200 "$tmp/l.err")"; fi

# non-empty dest refused, and untouched
mkdir -p "$tmp/ne" && echo keep >"$tmp/ne/f"
if A --dest "$tmp/ne" --layout single --module service-go --slot SERVICE=x --slot OWNER=y >/dev/null 2>&1; then fail "non-empty dest accepted"
elif [[ "$(ls "$tmp/ne")" == "f" ]]; then pass "non-empty dest refused, untouched"; else fail "non-empty dest modified"; fi

# unknown slot / module / layout -> exit 2
A --dest "$tmp/u1" --layout single --module service-go --slot SERVICE=x --slot OWNER=y --slot NOPE=z >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && pass "unknown slot exit 2" || fail "unknown slot" "rc=$rc"
A --dest "$tmp/u2" --layout single --module nope --slot SERVICE=x --slot OWNER=y >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && pass "unknown module exit 2" || fail "unknown module" "rc=$rc"
A --dest "$tmp/u3" --layout nope --module service-go --slot SERVICE=x --slot OWNER=y >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && pass "unknown layout exit 2" || fail "unknown layout" "rc=$rc"

# monorepo: unit under services/<SERVICE>/, root-only files at the root
mo="$tmp/mono"
if A --dest "$mo" --layout monorepo --module service-go --slot SERVICE=ledger --slot OWNER=acme >/dev/null 2>"$tmp/mo.err" \
  && [[ -f "$mo/services/ledger/go.mod" && -f "$mo/services/ledger/cmd/ledger/main.go" && -f "$mo/CODEOWNERS" \
        && -d "$mo/.github" && -f "$mo/AGENTS.md" && -d "$mo/scripts" \
        && ! -e "$mo/go.mod" && ! -e "$mo/CODEOWNERS.x" && ! -e "$mo/services/ledger/CODEOWNERS" \
        && ! -e "$mo/services/ledger/.github" && ! -e "$mo/cmd" ]]; then pass "monorepo placement"
else fail "monorepo placement" "$(head -c 200 "$tmp/mo.err")"; fi

# determinism: same inputs twice -> identical trees and modes
A --dest "$tmp/d1" --layout monorepo --module service-go --slot SERVICE=ledger --slot OWNER=acme >/dev/null 2>&1
if diff -r "$mo" "$tmp/d1" >/dev/null && [[ "$(modes "$mo")" == "$(modes "$tmp/d1")" ]]; then pass "deterministic"; else fail "not deterministic"; fi

echo "$ok ok, $bad failed"
(( ok + bad > 0 )) || exit 2
(( bad == 0 ))
