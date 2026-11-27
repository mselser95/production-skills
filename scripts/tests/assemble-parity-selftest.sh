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

# ---- scratch-module cases (own --modules-dir; manifests are written here) ----
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
sm="$tmp/sm"; mkdir -p "$sm"
# mkmod <id> <manifest-json>   (files are added by the caller under $sm/<id>)
mkmod() { mkdir -p "$sm/$1"; printf '%s\n' "$2" >"$sm/$1/module.json"; }
run() { # <dest-name> <layout> <modules...> -- slots...   -> sets rc, err file $tmp/<dest>.err
  local dn="$1" lay="$2"; shift 2; local mm=() ss=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do mm+=(--module "$1"); shift; done
  shift; for x in "$@"; do ss+=(--slot "$x"); done
  MODS="$sm" A --dest "$tmp/$dn" --layout "$lay" "${mm[@]}" "${ss[@]}" >"$tmp/$dn.out" 2>"$tmp/$dn.err"; rc=$?
}
M1='{"id":"X","source":".","slots":{},"placement":{"**":"unit"}}'

# git work tree: git-ignored build output is not assembled; module.json never shipped
mkmod gi "$M1"; echo hi >"$sm/gi/a.txt"; mkdir -p "$sm/gi/target/deep"; echo j >"$sm/gi/target/deep/x.o"
printf 'target/\n' >"$sm/gi/.gitignore"
git -C "$sm/gi" init -q 2>/dev/null; git -C "$sm/gi" add a.txt >/dev/null 2>&1
run gi single gi --
if [[ $rc -eq 0 && -f "$tmp/gi/a.txt" && -f "$tmp/gi/.gitignore" && ! -e "$tmp/gi/target" && ! -e "$tmp/gi/module.json" ]]; then
  pass "git: ignored target/ not assembled, no refusal, module.json not shipped"
else fail "git ignore" "rc=$rc $(head -c 200 "$tmp/gi.err")"; fi

# tracked file deleted from the working tree: skipped, no crash
git -C "$sm/gi" add .gitignore >/dev/null 2>&1; rm "$sm/gi/a.txt"
run gd single gi --
if [[ $rc -eq 0 && ! -e "$tmp/gd/a.txt" && -f "$tmp/gd/.gitignore" ]]; then pass "git: tracked-but-deleted file skipped"
else fail "git deleted" "rc=$rc $(head -c 200 "$tmp/gd.err")"; fi

# outside git: walk fallback; junk without exclude is refused (unplaced), with exclude it is not assembled
MW='{"id":"X","source":".","slots":{},"placement":{"*.txt":"unit"}}'
mkmod nw "$MW"; echo hi >"$sm/nw/a.txt"; mkdir -p "$sm/nw/target"; echo j >"$sm/nw/target/x.o"
run nw1 single nw --
if [[ $rc -eq 1 ]] && grep -q 'unplaced: target/x.o' "$tmp/nw1.err" && ! grep -q 'module.json' "$tmp/nw1.err"; then pass "walk: junk without exclude refused; module.json not reported"
else fail "walk junk" "rc=$rc $(head -c 200 "$tmp/nw1.err")"; fi
mkmod nw '{"id":"X","source":".","slots":{},"exclude":["target/**"],"placement":{"*.txt":"unit"}}'
run nw2 single nw --
if [[ $rc -eq 0 && -f "$tmp/nw2/a.txt" && ! -e "$tmp/nw2/target" && ! -e "$tmp/nw2/module.json" ]]; then pass "walk: exclude keeps target/ out"
else fail "walk exclude" "rc=$rc $(head -c 200 "$tmp/nw2.err")"; fi

# service-go: git path and walk path agree (ignored-file exclusion does not change the result)
mkdir -p "$tmp/w/prod-new/modules"; cp -R "$here/prod-new/template" "$tmp/w/prod-new/template"; cp -R "$mods/service-go" "$tmp/w/prod-new/modules/"
MODS="$tmp/w/prod-new/modules" A --dest "$tmp/wk" --layout single --module service-go --slot SERVICE=payments --slot OWNER=acme >/dev/null 2>&1
if diff -r "$tmp/p1/a" "$tmp/wk" >/dev/null && [[ "$(modes "$tmp/p1/a")" == "$(modes "$tmp/wk")" ]]; then pass "service-go: git list == walk list (tree and modes)"
else fail "git vs walk differ for service-go"; fi

# root collisions
mkmod ra '{"id":"ra","source":"f","slots":{},"placement":{"**":"root"}}'; mkdir -p "$sm/ra/f"
mkmod rb '{"id":"rb","source":"f","slots":{},"placement":{"**":"root"}}'; mkdir -p "$sm/rb/f"
echo same >"$sm/ra/f/CODEOWNERS"; echo same >"$sm/rb/f/CODEOWNERS"; echo a >"$sm/ra/f/only-a"
run c1 single ra rb --
if [[ $rc -eq 0 && "$(cat "$tmp/c1/CODEOWNERS")" == same && -f "$tmp/c1/only-a" ]]; then pass "identical root files written once"
else fail "identical root files" "rc=$rc $(head -c 200 "$tmp/c1.err")"; fi
echo different >"$sm/rb/f/CODEOWNERS"
run c2 single ra rb --
if [[ $rc -eq 1 ]] && grep -q 'modules ra and rb' "$tmp/c2.err" && grep -q 'CODEOWNERS' "$tmp/c2.err" && grep -q 'monorepo-root' "$tmp/c2.err" && [[ ! -e "$tmp/c2" ]]; then pass "differing root files: error names both modules and path"
else fail "differing root files" "rc=$rc $(head -c 300 "$tmp/c2.err")"; fi

# root_merge union-lines
mkmod ma '{"id":"ma","source":"f","slots":{},"root_merge":{".gitignore":"union-lines"},"placement":{"**":"root"}}'; mkdir -p "$sm/ma/f"
mkmod mb '{"id":"mb","source":"f","slots":{},"root_merge":{".gitignore":"union-lines"},"placement":{"**":"root"}}'; mkdir -p "$sm/mb/f"
printf 'b\na\nc\n' >"$sm/ma/f/.gitignore"; printf 'c\nd\na\ne\n' >"$sm/mb/f/.gitignore"
run u1 single ma mb --
if [[ $rc -eq 0 && "$(tr '\n' ',' <"$tmp/u1/.gitignore")" == "b,a,c,d,e," ]]; then pass "union-lines: stable, de-duplicated, first-seen order"
else fail "union-lines" "rc=$rc got $(tr '\n' ',' <"$tmp/u1/.gitignore" 2>/dev/null)"; fi
run u2 single mb ma --
[[ "$(tr '\n' ',' <"$tmp/u2/.gitignore" 2>/dev/null)" == "c,d,a,e,b," ]] && pass "union-lines: order follows module order" || fail "union-lines order"
mkmod mc '{"id":"mc","source":"f","slots":{},"placement":{"**":"root"}}'; mkdir -p "$sm/mc/f"; echo z >"$sm/mc/f/.gitignore"
run u3 single ma mc --
[[ $rc -eq 1 ]] && pass "union-lines needs every contributor to opt in" || fail "partial root_merge" "rc=$rc"
mkmod mx '{"id":"mx","source":"f","slots":{},"root_merge":{"*.yaml":"deep-merge"},"placement":{"**":"root"}}'; mkdir -p "$sm/mx/f"; echo q >"$sm/mx/f/q"
run u4 single mx --
if [[ $rc -eq 2 ]] && grep -q 'deep-merge' "$tmp/u4.err"; then pass "unknown merge strategy exit 2"; else fail "unknown strategy" "rc=$rc"; fi

# strict_slots, slot_allow
mkmod st '{"id":"st","source":"f","slots":{},"strict_slots":true,"placement":{"**":"root"}}'; mkdir -p "$sm/st/f"
printf 'ok <TAB> and <FOO> here\n' >"$sm/st/f/a.md"
run s1 single st --
if [[ $rc -eq 1 ]] && grep -q 'file: a.md.*<FOO>' "$tmp/s1.err"; then pass "strict_slots: stray <FOO> refused"; else fail "strict refuse" "rc=$rc $(head -c 200 "$tmp/s1.err")"; fi
mkmod st '{"id":"st","source":"f","slots":{},"strict_slots":true,"slot_allow":["TAB","FOO"],"placement":{"**":"root"}}'
run s2 single st --
[[ $rc -eq 0 ]] && pass "strict_slots: slot_allow accepts" || fail "slot_allow" "rc=$rc $(head -c 200 "$tmp/s2.err")"
mkmod st '{"id":"st","source":"f","slots":{},"placement":{"**":"root"}}'
run s3 single st --
[[ $rc -eq 0 ]] && pass "non-strict module tolerates stray tokens" || fail "non-strict" "rc=$rc"

# literal slots: contents and paths; unused literal is an error
mkmod li '{"id":"li","source":"f","slots":{"SCOPE":{"description":"scope","literal":"ds-scope"}},"placement":{"**":"root"}}'; mkdir -p "$sm/li/f/ds-scope"
echo 'import "ds-scope/x"' >"$sm/li/f/ds-scope/index.js"
run l1 single li -- SCOPE=acme-ui
if [[ $rc -eq 0 && "$(cat "$tmp/l1/acme-ui/index.js" 2>/dev/null)" == 'import "acme-ui/x"' ]]; then pass "literal slot substituted in path and contents"
else fail "literal slot" "rc=$rc $(head -c 200 "$tmp/l1.err")"; fi
mkmod lj '{"id":"lj","source":"f","slots":{"SCOPE":{"description":"scope","literal":"nowhere-token"}},"placement":{"**":"root"}}'; mkdir -p "$sm/lj/f"; echo plain >"$sm/lj/f/a"
run l2 single lj -- SCOPE=x
if [[ $rc -eq 1 ]] && grep -q 'never occurs' "$tmp/l2.err" && [[ ! -e "$tmp/l2" ]]; then pass "literal that never occurs is an error"
else fail "unused literal" "rc=$rc $(head -c 200 "$tmp/l2.err")"; fi

# determinism with scratch modules
run u5 single ma mb --
diff -r "$tmp/u1" "$tmp/u5" >/dev/null && pass "union assembly deterministic" || fail "union assembly not deterministic"

echo "$ok ok, $bad failed"
(( ok + bad > 0 )) || exit 2
(( bad == 0 ))
