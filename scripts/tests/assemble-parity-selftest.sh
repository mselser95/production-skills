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
A() { python3 -I -B "${USE:-$asm}" --modules-dir "${MODS:-$mods}" "$@"; }
modes() { (cd "$1" && find . -type f -exec ls -ld {} + | awk '{print substr($1,1,10), $NF}' | LC_ALL=C sort); }

parity() { # <label> <svc> <owner>
  local d="$tmp/$1"
  A --dest "$d/a" --layout single --module service-go --slot "SERVICE=$2" --slot "OWNER=$3" --strict-tracked >/dev/null 2>"$d.err" \
    || { fail "$1 assemble" "$(head -c 200 "$d.err")"; return; }
  (cd "$here" && bash "$inst" "$d/b" "$2" "$3") >/dev/null 2>&1 || { fail "$1 instantiate failed"; return; }
  if diff -r "$d/a" "$d/b" >"$d.diff" 2>&1; then pass "$1 diff -r empty"; else fail "$1 diff -r" "$(head -c 200 "$d.diff")"; fi
  if [[ "$(modes "$d/a")" == "$(modes "$d/b")" ]] && [[ -n "$(modes "$d/a")" ]]; then
    pass "$1 file modes equal"
  else fail "$1 file modes differ"; fi
}

parity p1 payments acme
parity p2 order-book some-org

# placement glob dropped from a COPY of the manifest -> a file is unplaced -> refused
mkdir -p "$tmp/m/prod-new/modules/service-go"
cp -R "$here/prod-new/template" "$tmp/m/prod-new/template"
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
  MODS="$sm" A --dest "$tmp/$dn" --layout "$lay" "${mm[@]}" "${ss[@]}" ${AFLAGS:-} >"$tmp/$dn.out" 2>"$tmp/$dn.err"; rc=$?
}
M1='{"id":"gi","source":".","slots":{},"placement":{"**":"unit"}}'

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
MW='{"id":"nw","source":".","slots":{},"placement":{"*.txt":"unit"}}'
mkmod nw "$MW"; echo hi >"$sm/nw/a.txt"; mkdir -p "$sm/nw/target"; echo j >"$sm/nw/target/x.o"
run nw1 single nw --
if [[ $rc -eq 1 ]] && grep -q 'unplaced: target/x.o' "$tmp/nw1.err" && ! grep -q 'module.json' "$tmp/nw1.err"; then pass "walk: junk without exclude refused; module.json not reported"
else fail "walk junk" "rc=$rc $(head -c 200 "$tmp/nw1.err")"; fi
mkmod nw '{"id":"nw","source":".","slots":{},"exclude":["target/**"],"placement":{"*.txt":"unit"}}'
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

# ======================= hardening cases (validator findings) =======================
rd() { tr '\n' ',' <"$1" 2>/dev/null; }
nolines() { ! grep -q Traceback "$1"; }
# runc <label> <layout> <modules...> -- slots...  : dest $tmp/<label>/dest next to a canary; logs outside
runc() {
  local lb="$1" lay="$2"; shift 2; local mm=() ss=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do mm+=(--module "$1"); shift; done
  shift; for x in "$@"; do ss+=(--slot "$x"); done
  mkdir -p "$tmp/$lb"; echo canary >"$tmp/$lb/canary"
  MODS="$sm" A --dest "$tmp/$lb/dest" --layout "$lay" "${mm[@]}" "${ss[@]}" ${AFLAGS:-} >"$tmp/log_$lb.out" 2>"$tmp/log_$lb.err"; rc=$?
}
untouched() { [[ "$(ls -A "$tmp/$1" | tr '\n' ' ')" == "canary " && "$(cat "$tmp/$1/canary")" == canary ]]; }
# mutant <from> <to> <out>: exact-once text replacement in a copy of the assembler (a rename makes this FAIL loudly)
mutant() {
  python3 -I - "$asm" "$1" "$2" "$3" <<'PY' || { fail "mutant marker missing: $1"; return 1; }
import sys
s = open(sys.argv[1]).read()
assert s.count(sys.argv[2]) == 1, sys.argv[2]
open(sys.argv[4], "w").write(s.replace(sys.argv[2], sys.argv[3]))
PY
}
mutant '    if VALUE_RX.fullmatch(v) is None:' '    if False:' "$tmp/m-nogram.py"
mutant '    if "\0" in rel or rel.startswith("/")' '    return False
    if "\0" in rel or rel.startswith("/")' "$tmp/m-noesc.py"
python3 -I - "$tmp/m-nogram.py" "$tmp/m-both.py" <<'PY'
import sys
s = open(sys.argv[1]).read()
a = '    if "\\0" in rel or rel.startswith("/")'
assert s.count(a) == 1
open(sys.argv[2], "w").write(s.replace(a, "    return False\n" + a))
PY

# ---- path escape: grammar (layer a) and escapes() (layer b) each stop it, canary untouched
mkmod esc '{"id":"esc","source":"f","slots":{"SERVICE":"s"},"placement":{"A-*":"root","cmd/**":"unit","*.md":"root"}}'
mkdir -p "$sm/esc/f/cmd/<SERVICE>"; echo 'package <SERVICE>' >"$sm/esc/f/cmd/<SERVICE>/main.go"
echo '# <SERVICE>' >"$sm/esc/f/<SERVICE>.md"; echo first >"$sm/esc/f/A-first"
mkdir -p "$tmp/absd"; echo keep >"$tmp/absd/EXIST.md"
esc_case() { # <label> <layout> <expect-rc> <expect-text> <slot value>   (USE=<assembler> optional)
  runc "$1" "$2" esc -- "SERVICE=$5"
  if [[ $rc -eq $3 ]] && grep -q -- "$4" "$tmp/log_$1.err" && nolines "$tmp/log_$1.err" && untouched "$1"; then pass "escape $1 refused (rc $3), canary untouched, no new sibling"
  else fail "escape $1" "rc=$rc $(head -c 160 "$tmp/log_$1.err") ls=$(ls -A "$tmp/$1" | tr '\n' ' ')"; fi
}
esc_case e1 single 2 grammar '../../ESC1'
esc_case e2 single 2 grammar 'a/../../../ESC3'
esc_case e3 monorepo 2 grammar '../../ESC4'
esc_case e4 single 2 grammar "$tmp/absd/EXIST"
[[ "$(cat "$tmp/absd/EXIST.md")" == keep ]] && pass "absolute-path SERVICE did not overwrite an existing file" || fail "existing file overwritten"
USE="$tmp/m-nogram.py" esc_case n1 single 1 escape '../../ESC1'
USE="$tmp/m-nogram.py" esc_case n3 monorepo 1 escape '../../ESC4'
USE="$tmp/m-nogram.py" esc_case n4 single 1 escape "$tmp/absd/NEW"
[[ ! -e "$tmp/absd/NEW.md" ]] && pass "escape layer alone: no file at the absolute path" || fail "absolute path written"
USE="$tmp/m-noesc.py" esc_case g1 single 2 grammar '../../ESC1'
USE="$tmp/m-both.py" runc b1 single esc -- 'SERVICE=../../ESC1'
if [[ -e "$tmp/b1/ESC1/main.go" ]]; then pass "both layers removed -> the escape really happens (cases are not vacuous)"; else fail "both removed but nothing escaped" "rc=$rc"; fi
mkmod up '{"id":"up","source":"f","slots":{"SERVICE":"s"},"placement":{"**":"unit"}}'; mkdir -p "$sm/up/f"; echo r >"$sm/up/f/README"
USE="$tmp/m-nogram.py" runc b2 monorepo up -- 'SERVICE=<BOGUS>'
if [[ $rc -eq 1 ]] && grep -q 'path: services/<BOGUS>/README' "$tmp/log_b2.err" && untouched b2; then pass "leftover token is checked on the FINAL path (unit prefix included)"
else fail "leftover on final path" "rc=$rc $(head -c 200 "$tmp/log_b2.err")"; fi

# ---- symlinks: copied as links; absolute/escaping refused; planned link as a prefix refused
mkmod la '{"id":"la","source":"f","slots":{},"placement":{"**":"root"}}'; mkdir -p "$sm/la/f/sub"; echo s >"$sm/la/f/sub/keep"; ln -s sub "$sm/la/f/d"
mkmod lb '{"id":"lb","source":"f","slots":{},"placement":{"**":"root"}}'; mkdir -p "$sm/lb/f/d"; echo x >"$sm/lb/f/d/f"
runc sl1 single la lb --
if [[ $rc -eq 1 ]] && grep -q 'path conflict' "$tmp/log_sl1.err" && grep -q 'la' "$tmp/log_sl1.err" && grep -q 'lb' "$tmp/log_sl1.err" && grep -q 'link' "$tmp/log_sl1.err" && nolines "$tmp/log_sl1.err" && untouched sl1 && [[ ! -e "$sm/la/f/sub/f" ]]; then
  pass "link redirect: module B cannot write beneath module A's link (both named, nothing written)"
else fail "link redirect" "rc=$rc $(head -c 200 "$tmp/log_sl1.err")"; fi
mkmod lc '{"id":"lc","source":"f","slots":{},"placement":{"**":"root"}}'; mkdir -p "$sm/lc/f"; ln -s /outside "$sm/lc/f/d2"
runc sl2 single lc --
[[ $rc -eq 1 ]] && grep -q 'link: d2 -> /outside' "$tmp/log_sl2.err" && untouched sl2 && pass "absolute link target refused" || fail "absolute link" "rc=$rc $(head -c 200 "$tmp/log_sl2.err")"
rm "$sm/lc/f/d2"; ln -s ../../x "$sm/lc/f/d3"
runc sl3 single lc --
[[ $rc -eq 1 ]] && grep -q 'link: d3' "$tmp/log_sl3.err" && pass "link escaping the module tree refused" || fail "escaping link" "rc=$rc"
rm "$sm/lc/f/d3"; echo real >"$sm/lc/f/real"; ln -s real "$sm/lc/f/lnk"
run sl4 single lc --
if [[ $rc -eq 0 && -L "$tmp/sl4/lnk" && "$(readlink "$tmp/sl4/lnk")" == real && "$(cat "$tmp/sl4/lnk")" == real ]]; then pass "relative in-tree link copied as a link"; else fail "link copy" "rc=$rc"; fi
mkdir -p "$tmp/emp"; ln -s "$tmp/emp" "$tmp/dlink"
run dlink single lc --
if [[ $rc -eq 1 ]] && grep -q 'symlink' "$tmp/dlink.err" && [[ -L "$tmp/dlink" && -z "$(ls -A "$tmp/emp")" ]]; then pass "dest that is a symlink refused, target untouched"; else fail "dest symlink" "rc=$rc $(head -c 160 "$tmp/dlink.err")"; fi

# ---- atomicity: file/dir conflict and a mid-write failure leave dest untouched
mkmod fa '{"id":"fa","source":"f","slots":{},"placement":{"**":"root"}}'; mkdir -p "$sm/fa/f"; echo f >"$sm/fa/f/x"
mkmod fb '{"id":"fb","source":"f","slots":{},"placement":{"**":"root"}}'; mkdir -p "$sm/fb/f/x"; echo y >"$sm/fb/f/x/y"
runc fd single fa fb --
if [[ $rc -eq 1 ]] && grep -q 'path conflict' "$tmp/log_fd.err" && grep -q 'fa' "$tmp/log_fd.err" && grep -q 'fb' "$tmp/log_fd.err" && nolines "$tmp/log_fd.err" && untouched fd; then
  pass "file vs directory conflict: both modules named, exit 1, no traceback, nothing written"
else fail "file/dir conflict" "rc=$rc $(head -c 200 "$tmp/log_fd.err")"; fi
long="$(printf 'z%.0s' $(seq 1 300))"
runc at single esc -- "SERVICE=$long"
if [[ $rc -eq 1 ]] && grep -q 'nothing written' "$tmp/log_at.err" && nolines "$tmp/log_at.err" && untouched at; then
  pass "mid-write failure (name too long): dest absent, temp dir removed, one-line error"
else fail "atomic write" "rc=$rc $(head -c 160 "$tmp/log_at.err") ls=$(ls -A "$tmp/at" | tr '\n' ' ')"; fi

# ---- slots: order independence (one pass), literal boundaries
mkmod ord '{"id":"ord","source":"f","slots":{"SERVICE":"s","LIT":{"description":"l","literal":"foo"}},"placement":{"**":"root"}}'
mkdir -p "$sm/ord/f"; echo '<SERVICE> and foo' >"$sm/ord/f/t.txt"
run o1 single ord -- SERVICE=foo LIT=bar
run o2 single ord -- LIT=bar SERVICE=foo
if diff -r "$tmp/o1" "$tmp/o2" >/dev/null && [[ "$(cat "$tmp/o1/t.txt")" == 'foo and bar' ]]; then pass "slot order does not change the tree; a substituted value is never re-scanned"
else fail "slot order" "$(cat "$tmp/o1/t.txt" 2>/dev/null) | $(cat "$tmp/o2/t.txt" 2>/dev/null)"; fi
mkmod bd '{"id":"bd","source":"f","slots":{"SCOPE":{"description":"s","literal":"acme"}},"placement":{"**":"root"}}'
mkdir -p "$sm/bd/f/acme"; echo 'x' >"$sm/bd/f/acme/x.txt"; echo 'y' >"$sm/bd/f/acmes.txt"
echo '@acme/pkg acmes xacme acme_x acme.' >"$sm/bd/f/c.txt"
run bd1 single bd -- SCOPE=ui9
if [[ $rc -eq 0 && "$(cat "$tmp/bd1/c.txt")" == '@ui9/pkg acmes xacme acme_x ui9.' && -f "$tmp/bd1/ui9/x.txt" && -f "$tmp/bd1/acmes.txt" ]]; then
  pass "literal boundary: @acme/pkg and acme/ hit; acmes, xacme, acme_x do not"
else fail "literal boundary" "rc=$rc $(cat "$tmp/bd1/c.txt" 2>/dev/null)"; fi
mkmod sh '{"id":"sh","source":"f","slots":{"SCOPE":{"description":"s","literal":"ab"}},"placement":{"**":"root"}}'; mkdir -p "$sm/sh/f"; echo ab >"$sm/sh/f/a"
run sh1 single sh -- SCOPE=x
[[ $rc -eq 2 ]] && grep -q 'at least 3' "$tmp/sh1.err" && pass "literal shorter than 3 chars: exit 2" || fail "short literal" "rc=$rc"
mkmod lc2 '{"id":"lc2","source":"f","slots":{"SCOPE":{"description":"d","literal":"ds-scope"}},"placement":{"**":"root"}}'
mkdir -p "$sm/lc2/f"; echo 'ds-scope <SCOPE>' >"$sm/lc2/f/a"
run lc2 single lc2 -- SCOPE=ui
[[ $rc -eq 1 ]] && grep -q 'file: a' "$tmp/lc2.err" && [[ ! -e "$tmp/lc2" ]] && pass "leftover <SCOPE> token in contents refused" || fail "leftover content" "rc=$rc $(head -c 160 "$tmp/lc2.err")"
mkmod tw '{"id":"tw","source":"f","slots":{"SCOPE":{"description":"d","literal":"acme"}},"placement":{"**":"root"}}'
mkdir -p "$sm/tw/f"; echo one >"$sm/tw/f/acme.txt"; echo two >"$sm/tw/f/ui9.txt"
run tw single tw -- SCOPE=ui9
[[ $rc -eq 1 ]] && grep -q 'module tw places ui9.txt twice' "$tmp/tw.err" && pass "collision inside one module names that module" || fail "single-module collision" "rc=$rc $(head -c 200 "$tmp/tw.err")"

# ---- first match, declared-slot refusal, modes, link-vs-file
mkmod fm '{"id":"fm","source":"f","slots":{"SERVICE":"s"},"placement":{"*.txt":"root","**":"unit"}}'
mkdir -p "$sm/fm/f"; echo a >"$sm/fm/f/a.txt"; echo b >"$sm/fm/f/b.dat"
run fm single fm -- SERVICE=x; run fm2 monorepo fm -- SERVICE=svc
if [[ -f "$tmp/fm2/a.txt" && -f "$tmp/fm2/services/svc/b.dat" && ! -e "$tmp/fm2/services/svc/a.txt" ]]; then pass "first matching glob wins (monorepo: root vs unit)"; else fail "first match" "rc=$rc"; fi
mkmod ms '{"id":"ms","source":"f","slots":{"SERVICE":"s","OWNER":"o"},"placement":{"**":"root"}}'; mkdir -p "$sm/ms/f"; echo x >"$sm/ms/f/a"
run ms single ms -- SERVICE=x
[[ $rc -eq 2 ]] && grep -q "'OWNER'.*not given" "$tmp/ms.err" && [[ ! -e "$tmp/ms" ]] && pass "declared slot not given: exit 2, nothing written" || fail "missing slot" "rc=$rc"
mkmod ia '{"id":"ia","source":"f","slots":{},"placement":{"**":"root"}}'; mkdir -p "$sm/ia/f"; echo same >"$sm/ia/f/s.sh"
mkmod ib '{"id":"ib","source":"f","slots":{},"placement":{"**":"root"}}'; mkdir -p "$sm/ib/f"; echo same >"$sm/ib/f/s.sh"; chmod 755 "$sm/ib/f/s.sh"
run im single ia ib --
[[ $rc -eq 1 ]] && grep -q 'different mode' "$tmp/im.err" && pass "same bytes, different mode: refused as 'different mode'" || fail "mode compare" "rc=$rc $(head -c 200 "$tmp/im.err")"
mkmod ka '{"id":"ka","source":"f","slots":{},"placement":{"**":"root"}}'; mkdir -p "$sm/ka/f"; ln -s t "$sm/ka/f/n"
mkmod kb '{"id":"kb","source":"f","slots":{},"placement":{"**":"root"}}'; mkdir -p "$sm/kb/f"; echo t >"$sm/kb/f/n"
run lf single ka kb --
[[ $rc -eq 1 ]] && grep -q 'link vs file' "$tmp/lf.err" && pass "link vs file collision says so" || fail "link vs file" "rc=$rc $(head -c 200 "$tmp/lf.err")"
mkmod nz '{"id":"nz","source":"f","slots":{},"placement":{"**":"unit"}}'; mkdir -p "$sm/nz/f"; echo z >"$sm/nz/f/z"
runc nz monorepo nz --
[[ $rc -eq 2 ]] && grep -q 'module nz' "$tmp/log_nz.err" && grep -q SERVICE "$tmp/log_nz.err" && untouched nz && pass "monorepo unit placement without a SERVICE slot: exit 2 naming the module" || fail "monorepo no SERVICE" "rc=$rc $(head -c 200 "$tmp/log_nz.err")"

# ---- union-lines rules
mkum() { mkmod "$1" "{\"id\":\"$1\",\"source\":\"f\",\"slots\":{},\"root_merge\":{\".gitignore\":\"union-lines\"},\"placement\":{\"**\":\"root\"}}"; mkdir -p "$sm/$1/f"; }
mkum un1; printf 'a\na\nb\n' >"$sm/un1/f/.gitignore"
mkum un2; printf 'b\nc\nc\n' >"$sm/un2/f/.gitignore"
run un12 single un1 un2 --
[[ $rc -eq 0 && "$(rd "$tmp/un12/.gitignore")" == "a,a,b,c,c," ]] && pass "union-lines: no de-dup within a file, only an already-present later line dropped" || fail "union dup" "rc=$rc got $(rd "$tmp/un12/.gitignore")"
mkum un3; printf 'x\r\ny\r\n' >"$sm/un3/f/.gitignore"
run un13 single un1 un3 --
[[ $rc -eq 1 ]] && grep -q 'CRLF' "$tmp/un13.err" && [[ ! -e "$tmp/un13" ]] && pass "union-lines: CRLF vs LF between contributors is an error" || fail "union eol" "rc=$rc $(head -c 200 "$tmp/un13.err")"
mkum un4; printf 'q\n' >"$sm/un4/f/.gitignore"; chmod 755 "$sm/un4/f/.gitignore"
run un14 single un1 un4 --
[[ $rc -eq 1 ]] && grep -q 'different mode' "$tmp/un14.err" && pass "union-lines: contributors must agree on mode" || fail "union mode" "rc=$rc $(head -c 200 "$tmp/un14.err")"
mkum un5; printf 'q' >"$sm/un5/f/.gitignore"
run un15 single un1 un5 --
[[ $rc -eq 1 ]] && grep -q 'trailing newline' "$tmp/un15.err" && pass "union-lines: a missing final newline is an error, not normalised" || fail "union eof" "rc=$rc $(head -c 200 "$tmp/un15.err")"

# ---- git: neutralised user config, GIT_* stripped, --strict-tracked
mkmod gg '{"id":"gg","source":"f","slots":{},"placement":{"**":"root"}}'
git -C "$sm/gg" init -q 2>/dev/null; mkdir -p "$sm/gg/f"; echo t >"$sm/gg/f/a.txt"; echo y >"$sm/gg/f/x.yaml"; echo l >"$sm/gg/f/y.log"
printf '*.log\n' >"$sm/gg/.gitignore"; git -C "$sm/gg" add f/a.txt >/dev/null 2>&1
printf '*.yaml\n' >"$tmp/gign"; printf '[core]\n\texcludesFile = %s\n' "$tmp/gign" >"$tmp/gcfg"
GIT_CONFIG_GLOBAL="$tmp/gcfg" run gg1 single gg --
if [[ $rc -eq 0 && -f "$tmp/gg1/x.yaml" && -f "$tmp/gg1/a.txt" && ! -e "$tmp/gg1/y.log" ]]; then pass "global gitignore neutralised (untracked .yaml ships); a parent .gitignore still applies"
else fail "global ignore" "rc=$rc $(head -c 160 "$tmp/gg1.err")"; fi
GIT_CONFIG_GLOBAL="$tmp/gcfg" AFLAGS=--strict-tracked run gg2 single gg --
[[ $rc -eq 1 ]] && grep -q 'x.yaml' "$tmp/gg2.err" && [[ ! -e "$tmp/gg2" ]] && pass "--strict-tracked refuses an untracked-not-ignored file" || fail "strict-tracked" "rc=$rc $(head -c 200 "$tmp/gg2.err")"
AFLAGS=--strict-tracked run gg3 single nw --
[[ $rc -eq 1 ]] && grep -q 'not inside a git work tree' "$tmp/gg3.err" && pass "--strict-tracked outside git refuses" || fail "strict outside git" "rc=$rc"
GIT_DIR="$tmp/no-such-git-dir" GIT_WORK_TREE="$tmp" run gs single gi --
if [[ $rc -eq 0 && ! -e "$tmp/gs/target" && -f "$tmp/gs/.gitignore" ]]; then pass "GIT_* variables are stripped (a hostile GIT_DIR does not change the listing)"
else fail "GIT_* stripping" "rc=$rc $(head -c 160 "$tmp/gs.err")"; fi

# ---- manifest errors: exit 2, the key named, never a traceback
mkdir -p "$sm/bm/f"; echo x >"$sm/bm/f/a"
mbad() { # <label> <manifest-json> <needle>
  printf '%s\n' "$2" >"$sm/bm/module.json"
  run "bm_$1" single bm --
  if [[ $rc -eq 2 ]] && grep -q -- "$3" "$tmp/bm_$1.err" && nolines "$tmp/bm_$1.err" && [[ ! -e "$tmp/bm_$1" ]]; then pass "manifest $1: exit 2 naming $3"
  else fail "manifest $1" "rc=$rc $(head -c 200 "$tmp/bm_$1.err")"; fi
}
P='"placement":{"**":"root"}'
mbad unknown-key "{\"id\":\"bm\",\"source\":\"f\",$P,\"bogus\":1}" bogus
mbad strict-type "{\"id\":\"bm\",\"source\":\"f\",$P,\"strict_slots\":\"yes\"}" strict_slots
mbad no-source "{\"id\":\"bm\",$P}" "'source'"
mbad no-placement '{"id":"bm","source":"f"}' "'placement'"
mbad no-id "{\"source\":\"f\",$P}" "'id'"
mbad id-mismatch "{\"id\":\"other\",\"source\":\"f\",$P}" "'id'"
mbad src-abs "{\"id\":\"bm\",\"source\":\"/etc\",$P}" "'source'"
mbad src-escape "{\"id\":\"bm\",\"source\":\"../../../../..\",$P}" "outside"
mbad slots-list "{\"id\":\"bm\",\"source\":\"f\",$P,\"slots\":[]}" "'slots'"
mbad place-type '{"id":"bm","source":"f","placement":{"**":5}}' "'placement'"
mbad not-object '[]' "JSON object"
mbad bad-json '{' "unreadable"
mbad slot-key "{\"id\":\"bm\",\"source\":\"f\",$P,\"slots\":{\"A\":{\"nope\":1}}}" "unknown key"
mbad bad-pattern "{\"id\":\"bm\",\"source\":\"f\",$P,\"slots\":{\"A\":{\"pattern\":\"(\"}}}" "pattern"
mbad exclude-type "{\"id\":\"bm\",\"source\":\"f\",$P,\"exclude\":\"x\"}" "'exclude'"
mbad slot-name "{\"id\":\"bm\",\"source\":\"f\",$P,\"slots\":{\"lower\":\"d\"}}" "slot name"

# ---- requires / conflicts are enforced; pattern narrows, never widens
mkmod rq '{"id":"rq","requires":["gi"],"source":"f","slots":{},"placement":{"**":"root"}}'; mkdir -p "$sm/rq/f"; echo r >"$sm/rq/f/rq.txt"
run rq1 single rq --
[[ $rc -eq 1 ]] && grep -q 'requires module gi' "$tmp/rq1.err" && pass "requires enforced (missing module -> exit 1)" || fail "requires" "rc=$rc $(head -c 160 "$tmp/rq1.err")"
run rq2 single rq gi --
[[ $rc -eq 0 ]] && pass "requires satisfied when the module is selected" || fail "requires satisfied" "rc=$rc $(head -c 160 "$tmp/rq2.err")"
mkmod cf '{"id":"cf","conflicts":["rq"],"source":"f","slots":{},"placement":{"**":"root"}}'; mkdir -p "$sm/cf/f"; echo c >"$sm/cf/f/cf.txt"
run cf1 single cf rq gi --
[[ $rc -eq 1 ]] && grep -q 'conflicts with module' "$tmp/cf1.err" && pass "conflicts enforced (exit 1)" || fail "conflicts" "rc=$rc $(head -c 160 "$tmp/cf1.err")"
mkmod pt '{"id":"pt","source":"f","slots":{"NAME":{"description":"n","pattern":"[a-z]+"}},"placement":{"**":"root"}}'; mkdir -p "$sm/pt/f"; echo '<NAME>' >"$sm/pt/f/t"
run pt1 single pt -- NAME=abc; r1=$rc; run pt2 single pt -- NAME=Abc; r2=$rc
[[ $r1 -eq 0 && $r2 -eq 2 ]] && grep -q 'pattern' "$tmp/pt2.err" && pass "slot pattern narrows the grammar" || fail "pattern narrowing" "$r1/$r2"
mkmod pw '{"id":"pw","source":"f","slots":{"NAME":{"description":"n","pattern":".*"}},"placement":{"**":"root"}}'; mkdir -p "$sm/pw/f"; echo '<NAME>' >"$sm/pw/f/t"
run pw1 single pw -- NAME=a/b
[[ $rc -eq 2 ]] && grep -q 'grammar' "$tmp/pw1.err" && pass "a pattern of .* cannot widen the grammar" || fail "pattern widening" "rc=$rc"
run so1 single esc -- 'SERVICE=<OWNER>'; r1=$rc
[[ $r1 -eq 2 ]] && pass "SERVICE=<OWNER> refused (no order dependence left)" || fail "placeholder value" "rc=$r1"

# ---- value-grammar parity: both tools accept/refuse the same values, accepted ones are identical
mx="$tmp/mx"; mt="$mx/prod-new/template"; mkdir -p "$mx/prod-new/modules" "$mt/cmd/<SERVICE>" "$mt/scripts"
cp -R "$mods/service-go" "$mx/prod-new/modules/"
printf 'package main // <SERVICE> <OWNER>\n' >"$mt/cmd/<SERVICE>/main.go"; printf '* @<OWNER>\n' >"$mt/CODEOWNERS"
printf '#!/bin/sh\necho <SERVICE>\n' >"$mt/scripts/run.sh"; chmod 755 "$mt/scripts/run.sh"; printf '# <SERVICE>\n' >"$mt/README.md"
vparity() { # <label> <expect ok|refuse> <svc> <owner>
  local d="$tmp/vp_$1"; mkdir -p "$d"
  MODS="$mx/prod-new/modules" A --dest "$d/a" --layout single --module service-go --slot "SERVICE=$3" --slot "OWNER=$4" >/dev/null 2>&1; local ra=$?
  (cd "$mx" && bash "$inst" "$d/b" "$3" "$4") >/dev/null 2>&1; local ri=$?
  local da=refuse di=refuse; [[ $ra -eq 0 ]] && da=ok; [[ $ri -eq 0 ]] && di=ok
  if [[ "$da" != "$2" || "$di" != "$2" ]]; then fail "value $1" "expected $2, assembler=$da template=$di"
  elif [[ "$2" == ok ]] && ! { diff -r "$d/a" "$d/b" >/dev/null && [[ "$(modes "$d/a")" == "$(modes "$d/b")" ]]; }; then fail "value $1" "accepted by both but trees differ"
  else pass "value $1: both tools $2"; fi
}
for v in s a.b order-book A1_x 9lives; do vparity "ok-$v" ok "$v" acme; vparity "ok-owner-$v" ok svc "$v"; done
n=0
for v in 'a/b' 'a\b' 'a&b' '\1' 'a b' '-x' '.x' '..' '.' '../../E' '/abs' 'a<OWNER>' $'a\nb' $'a\n' 'a;b' "a'b" 'é' 'a$b'; do
  n=$((n + 1)); vparity "bad$n" refuse "$v" acme; vparity "bad-owner$n" refuse svc "$v"
done

echo "$ok ok, $bad failed"
(( ok + bad > 0 )) || exit 2
(( bad == 0 ))
